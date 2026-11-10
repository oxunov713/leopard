package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/leopard-vault/leopard/backend/internal/auth"
	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/store"
	"github.com/leopard-vault/leopard/backend/internal/totp"
)

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	if err := s.st.Ping(ctx); err != nil {
		s.log.Error("healthz: database unreachable", "err", err.Error())
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

type deviceInput struct {
	Label      string `json:"label"`
	Ed25519Pub string `json:"ed25519_pub"`
}

// parseDevice validates a device registration.
func parseDevice(w http.ResponseWriter, in deviceInput, now time.Time) (store.Device, bool) {
	label := strings.TrimSpace(in.Label)
	if label == "" || utf8.RuneCountInString(label) > maxLabelLen || !utf8.ValidString(label) {
		badRequest(w, "device.label must be 1-64 characters")
		return store.Device{}, false
	}
	pub, ok := b64field(w, "device.ed25519_pub", in.Ed25519Pub, 32)
	if !ok {
		return store.Device{}, false
	}
	return store.Device{ID: lcrypto.NewUUID(), Label: label, Ed25519Pub: pub, CreatedAt: now}, true
}

type setupRequest struct {
	KDFParams            lcrypto.KDFParams `json:"kdf_params"`
	Salt                 string            `json:"salt"`
	WrappedVKMaster      string            `json:"wrapped_vk_master"`
	WrappedVKRecovery    string            `json:"wrapped_vk_recovery"`
	MasterAuthVerifier   string            `json:"master_auth_verifier"`
	RecoveryAuthVerifier string            `json:"recovery_auth_verifier"`
	TOTPSecret           string            `json:"totp_secret"`
	Device               deviceInput       `json:"device"`
}

// handleSetup initialises the vault exactly once and registers the first device.
func (s *Server) handleSetup(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	if s.setup != "" && !auth.EqualString(r.Header.Get("X-Leopard-Setup-Token"), s.setup) {
		s.audit(r, "setup_denied", nil, nil, map[string]any{"reason": "bad_setup_token"})
		writeError(w, http.StatusForbidden, "setup_token_required", "a valid X-Leopard-Setup-Token header is required")
		return
	}
	var req setupRequest
	if !readJSON(w, r, &req) {
		return
	}
	if err := req.KDFParams.Validate(); err != nil {
		badRequest(w, "kdf_params: "+strings.TrimPrefix(err.Error(), "crypto: "))
		return
	}
	salt, ok := b64field(w, "salt", req.Salt, lcrypto.SaltSize)
	if !ok {
		return
	}
	wm, ok := b64field(w, "wrapped_vk_master", req.WrappedVKMaster, lcrypto.WrappedVKSize)
	if !ok {
		return
	}
	wr, ok := b64field(w, "wrapped_vk_recovery", req.WrappedVKRecovery, lcrypto.WrappedVKSize)
	if !ok {
		return
	}
	mv, ok := b64field(w, "master_auth_verifier", req.MasterAuthVerifier, 32)
	if !ok {
		return
	}
	rv, ok := b64field(w, "recovery_auth_verifier", req.RecoveryAuthVerifier, 32)
	if !ok {
		return
	}
	secret, ok := b64field(w, "totp_secret", req.TOTPSecret, -1)
	if !ok {
		return
	}
	if len(secret) < totp.MinSecretSize || len(secret) > totp.MaxSecretSize {
		badRequest(w, "totp_secret must be 16-64 bytes")
		return
	}
	now := s.now()
	dev, ok := parseDevice(w, req.Device, now)
	if !ok {
		return
	}
	sealed, err := s.box.Seal(secret, auth.LabelTOTP)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	params, _ := json.Marshal(req.KDFParams)
	v := store.Vault{
		KDFParams: params, Salt: salt, WrappedVKMaster: wm, WrappedVKRecovery: wr,
		MasterAuthVerifier: mv, RecoveryAuthVerifier: rv, TOTPSecretEnc: sealed, CreatedAt: now,
	}
	switch err := s.st.CreateVault(r.Context(), v, dev); {
	case errors.Is(err, store.ErrVaultExists):
		s.audit(r, "setup_denied", nil, nil, map[string]any{"reason": "already_initialised"})
		writeError(w, http.StatusConflict, "already_initialised", "the vault has already been set up")
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	s.audit(r, "vault_setup", nil, &dev.ID, map[string]any{"label": dev.Label})
	writeJSON(w, http.StatusCreated, map[string]any{"device_id": dev.ID, "created_at": now})
}

// ---- device challenge-response ----

type challengeRequest struct {
	DeviceID string `json:"device_id"`
}

func (s *Server) handleDeviceChallenge(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	var req challengeRequest
	if !readJSON(w, r, &req) {
		return
	}
	if !lcrypto.IsCanonicalUUID(req.DeviceID) {
		badRequest(w, "device_id must be a lower-case UUID")
		return
	}
	now := s.now()
	nonce := lcrypto.RandomBytes(lcrypto.DeviceChallengeSize)
	expires := now.Add(ChallengeLifetime)
	// A challenge is issued whether or not the device exists, so this
	// endpoint cannot be used to probe for valid device ids; it is only
	// stored for real, non-revoked devices.
	dev, err := s.st.GetDevice(r.Context(), req.DeviceID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.internal(w, r, err)
		return
	}
	if err == nil && dev.RevokedAt == nil {
		if err := s.st.PutChallenge(r.Context(), lcrypto.SHA256(nonce), req.DeviceID, expires); err != nil {
			s.internal(w, r, err)
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"nonce": lcrypto.B64(nonce), "expires_at": expires})
}

type verifyRequest struct {
	DeviceID  string `json:"device_id"`
	Nonce     string `json:"nonce"`
	Signature string `json:"signature"`
}

func (s *Server) handleDeviceVerify(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	var req verifyRequest
	if !readJSON(w, r, &req) {
		return
	}
	if !lcrypto.IsCanonicalUUID(req.DeviceID) {
		badRequest(w, "device_id must be a lower-case UUID")
		return
	}
	nonce, ok := b64field(w, "nonce", req.Nonce, lcrypto.DeviceChallengeSize)
	if !ok {
		return
	}
	sig, ok := b64field(w, "signature", req.Signature, 64)
	if !ok {
		return
	}
	now := s.now()
	fail := func(reason string) {
		s.audit(r, "device_auth_failed", nil, nil, map[string]any{"device_id": req.DeviceID, "reason": reason})
		writeError(w, http.StatusUnauthorized, "device_auth_failed", "device authentication failed")
	}
	// The challenge is consumed before the signature is checked: one nonce, one attempt.
	live, err := s.st.TakeChallenge(r.Context(), lcrypto.SHA256(nonce), req.DeviceID, now)
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !live {
		fail("unknown_or_expired_challenge")
		return
	}
	dev, err := s.st.GetDevice(r.Context(), req.DeviceID)
	if errors.Is(err, store.ErrNotFound) {
		fail("unknown_device")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if dev.RevokedAt != nil {
		fail("device_revoked")
		return
	}
	msg, err := lcrypto.DeviceAuthMessage(req.DeviceID, nonce)
	if err != nil || !lcrypto.Ed25519Verify(dev.Ed25519Pub, msg, sig) {
		fail("bad_signature")
		return
	}
	token, hash := auth.NewToken()
	sess := store.Session{
		ID: lcrypto.NewUUID(), Kind: store.KindMobile, DeviceID: &dev.ID, ClientInfo: s.observedClientInfo(r, nil),
		IP: s.clientIP(r), CreatedAt: now, LastSeen: now, IdleTimeoutSeconds: int(MobileIdleTimeout / time.Second),
	}
	if err := s.st.CreateSession(r.Context(), sess, hash); err != nil {
		s.internal(w, r, err)
		return
	}
	if err := s.st.TouchDevice(r.Context(), dev.ID, now); err != nil {
		s.internal(w, r, err)
		return
	}
	s.audit(r, "device_auth_ok", &sess.ID, &dev.ID, nil)
	writeJSON(w, http.StatusOK, sessionGrant(token, &sess))
}

// sessionGrant is the common body returned when a session token is issued.
func sessionGrant(token string, sess *store.Session) map[string]any {
	return map[string]any{
		"session_token":        token,
		"session_id":           sess.ID,
		"kind":                 sess.Kind,
		"idle_timeout_seconds": sess.IdleTimeoutSeconds,
	}
}

// observedClientInfo combines what the client reported about itself with the
// User-Agent the server saw. Both are untrusted, display-only hints.
func (s *Server) observedClientInfo(r *http.Request, reported json.RawMessage) json.RawMessage {
	m := map[string]any{}
	if ua := r.UserAgent(); ua != "" {
		if len(ua) > 256 {
			ua = ua[:256]
		}
		m["user_agent"] = strings.ToValidUTF8(ua, "")
	}
	if len(reported) > 0 {
		m["reported"] = reported
	}
	b, _ := json.Marshal(m)
	return b
}

// ---- emergency web login with master password + TOTP ----

func (s *Server) handleMasterParams(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	v, err := s.st.GetVault(r.Context())
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "not_initialised", "the vault has not been set up")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	// Deliberately NOT returned here: wrapped_vk_master. Handing it to an
	// unauthenticated caller would allow offline guessing of the master
	// password. It is released by /auth/master/login after TOTP + proof.
	writeJSON(w, http.StatusOK, map[string]any{"kdf_params": v.KDFParams, "salt": lcrypto.B64(v.Salt)})
}

type masterLoginRequest struct {
	TOTPCode   string          `json:"totp_code"`
	Proof      string          `json:"proof"`
	ClientInfo json.RawMessage `json:"client_info,omitempty"`
}

func (s *Server) handleMasterLogin(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	// The global bucket caps total guessing no matter how many addresses an
	// attacker has. The price is that a flood can lock out emergency login
	// for a while; QR login is unaffected.
	if !s.allow(w, ruleMasterLoginGlobal, "global") {
		return
	}
	var req masterLoginRequest
	if !readJSON(w, r, &req) {
		return
	}
	proof, ok := b64field(w, "proof", req.Proof, lcrypto.KeySize)
	if !ok {
		return
	}
	if !validClientInfo(w, req.ClientInfo) {
		return
	}
	fail := func(reason string) {
		s.audit(r, "master_login_failed", nil, nil, map[string]any{"reason": reason})
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "invalid credentials")
	}
	v, err := s.st.GetVault(r.Context())
	if errors.Is(err, store.ErrNotFound) {
		fail("not_initialised")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	secret, err := s.box.Open(v.TOTPSecretEnc, auth.LabelTOTP)
	if err != nil {
		// Wrong LEOPARD_SERVER_KEY for this database: an operator problem.
		s.internal(w, r, errors.New("cannot decrypt TOTP secret; LEOPARD_SERVER_KEY does not match the vault"))
		return
	}
	now := s.now()
	// Evaluate both factors unconditionally so the response does not reveal
	// which one was wrong.
	proofOK := lcrypto.CheckAuthKey(proof, v.MasterAuthVerifier)
	step, totpOK := totp.Verify(secret, req.TOTPCode, now)
	switch {
	case !proofOK && !totpOK:
		fail("bad_proof_and_totp")
		return
	case !proofOK:
		fail("bad_proof")
		return
	case !totpOK:
		fail("bad_totp")
		return
	}
	fresh, err := s.st.AdvanceTOTPStep(r.Context(), int64(step))
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !fresh {
		fail("totp_replay")
		return
	}
	token, hash := auth.NewToken()
	sess := store.Session{
		ID: lcrypto.NewUUID(), Kind: store.KindWeb, ClientInfo: s.observedClientInfo(r, req.ClientInfo),
		IP: s.clientIP(r), CreatedAt: now, LastSeen: now, IdleTimeoutSeconds: int(WebIdleTimeout / time.Second),
	}
	if err := s.st.CreateSession(r.Context(), sess, hash); err != nil {
		s.internal(w, r, err)
		return
	}
	s.audit(r, "master_login_ok", &sess.ID, nil, nil)
	out := sessionGrant(token, &sess)
	out["wrapped_vk_master"] = lcrypto.B64(v.WrappedVKMaster)
	writeJSON(w, http.StatusOK, out)
}

// validClientInfo accepts an absent value or a small JSON object.
func validClientInfo(w http.ResponseWriter, raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var obj map[string]any
	if len(raw) > maxClientInfoBytes || json.Unmarshal(raw, &obj) != nil {
		badRequest(w, "client_info must be a JSON object of at most 2 KiB")
		return false
	}
	return true
}

// ---- recovery ----

type recoveryRequest struct {
	Proof  string      `json:"proof"`
	Device deviceInput `json:"device"`
}

// handleRecovery registers a new device using the recovery key and revokes
// every existing device and session.
func (s *Server) handleRecovery(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	if !s.allow(w, ruleRecoveryGlobal, "global") {
		return
	}
	var req recoveryRequest
	if !readJSON(w, r, &req) {
		return
	}
	proof, ok := b64field(w, "proof", req.Proof, lcrypto.KeySize)
	if !ok {
		return
	}
	now := s.now()
	dev, ok := parseDevice(w, req.Device, now)
	if !ok {
		return
	}
	fail := func(reason string) {
		s.audit(r, "recovery_failed", nil, nil, map[string]any{"reason": reason})
		writeError(w, http.StatusUnauthorized, "invalid_credentials", "invalid credentials")
	}
	v, err := s.st.GetVault(r.Context())
	if errors.Is(err, store.ErrNotFound) {
		fail("not_initialised")
		return
	}
	if err != nil {
		s.internal(w, r, err)
		return
	}
	if !lcrypto.CheckAuthKey(proof, v.RecoveryAuthVerifier) {
		fail("bad_proof")
		return
	}
	if err := s.st.ReplaceDevices(r.Context(), dev, now); err != nil {
		s.internal(w, r, err)
		return
	}
	s.audit(r, "recovery_device_registered", nil, &dev.ID, map[string]any{"label": dev.Label})
	writeJSON(w, http.StatusCreated, map[string]any{
		"device_id":           dev.ID,
		"wrapped_vk_recovery": lcrypto.B64(v.WrappedVKRecovery),
		"kdf_params":          v.KDFParams,
		"salt":                lcrypto.B64(v.Salt),
	})
}
