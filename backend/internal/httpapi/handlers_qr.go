package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/leopard-vault/leopard/backend/internal/auth"
	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/store"
)

type qrCreateRequest struct {
	BrowserPub string          `json:"browser_pub"`
	ClientInfo json.RawMessage `json:"client_info,omitempty"`
}

// handleQRCreate starts a QR login. The browser gets the sid (which goes in
// the QR code) and a poll token (which does not): only the holder of the poll
// token can collect the result, so photographing the QR code is not enough.
func (s *Server) handleQRCreate(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	var req qrCreateRequest
	if !readJSON(w, r, &req) {
		return
	}
	pub, ok := b64field(w, "browser_pub", req.BrowserPub, lcrypto.X25519KeySize)
	if !ok {
		return
	}
	if !validClientInfo(w, req.ClientInfo) {
		return
	}
	now := s.now()
	sid := lcrypto.RandomBytes(lcrypto.SIDSize)
	pollToken, pollHash := auth.NewToken()
	q := store.QRRequest{
		SID: lcrypto.B64(sid), BrowserPub: pub, PollTokenHash: pollHash,
		ClientInfo: s.observedClientInfo(r, req.ClientInfo), IP: s.clientIP(r),
		CreatedAt: now, ExpiresAt: now.Add(QRLifetime), Status: store.QRPending,
	}
	if err := s.st.CreateQR(r.Context(), q); err != nil {
		s.internal(w, r, err)
		return
	}
	code, _ := lcrypto.VerifyCode(sid, pub)
	s.audit(r, "qr_created", nil, nil, map[string]any{"sid": q.SID})
	writeJSON(w, http.StatusCreated, map[string]any{
		"sid":         q.SID,
		"poll_token":  pollToken,
		"expires_at":  q.ExpiresAt,
		"verify_code": code,
		"qr_uri":      lcrypto.QRURI(sid, pub),
	})
}

// loadQR fetches the request named in the path, answering 404 itself.
func (s *Server) loadQR(w http.ResponseWriter, r *http.Request) (*store.QRRequest, []byte, bool) {
	sidStr := r.PathValue("sid")
	sid, err := lcrypto.UnB64(sidStr)
	if err != nil || len(sid) != lcrypto.SIDSize {
		writeError(w, http.StatusNotFound, "qr_not_found", "unknown QR request")
		return nil, nil, false
	}
	q, err := s.st.GetQR(r.Context(), sidStr)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "qr_not_found", "unknown QR request")
		return nil, nil, false
	}
	if err != nil {
		s.internal(w, r, err)
		return nil, nil, false
	}
	return q, sid, true
}

// effectiveStatus applies lazy expiry: the cleanup job flips the stored
// status later, but clients must see the truth immediately.
func effectiveStatus(q *store.QRRequest, now time.Time) string {
	switch {
	case q.Status == store.QRPending && !now.Before(q.ExpiresAt):
		return store.QRExpired
	case q.Status == store.QRApproved && q.ApprovedAt != nil && now.Sub(*q.ApprovedAt) > QRCollectWindow:
		return store.QRExpired
	}
	return q.Status
}

// handleQRPoll is polled by the browser. Once the phone has approved, exactly
// one poll receives the session token and key-transfer payload.
func (s *Server) handleQRPoll(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	q, _, ok := s.loadQR(w, r)
	if !ok {
		return
	}
	pollHash, valid := auth.HashToken(r.Header.Get("X-Leopard-Poll-Token"))
	if !valid || !auth.Equal(pollHash, q.PollTokenHash) {
		// Indistinguishable from an unknown sid.
		writeError(w, http.StatusNotFound, "qr_not_found", "unknown QR request")
		return
	}
	now := s.now()
	status := effectiveStatus(q, now)
	if status != store.QRApproved {
		writeJSON(w, http.StatusOK, map[string]any{"status": status, "expires_at": q.ExpiresAt})
		return
	}
	// The token is minted only now and only its hash is stored: the server
	// never holds a usable web session token at rest.
	token, hash := auth.NewToken()
	got, err := s.st.ConsumeQR(r.Context(), q.SID, hash, now, QRCollectWindow)
	switch {
	case errors.Is(err, store.ErrQRState):
		// Lost a race with another poll: it has already been collected.
		writeJSON(w, http.StatusOK, map[string]any{"status": store.QRConsumed, "expires_at": q.ExpiresAt})
		return
	case errors.Is(err, store.ErrQRExpired):
		writeJSON(w, http.StatusOK, map[string]any{"status": store.QRExpired, "expires_at": q.ExpiresAt})
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	s.audit(r, "qr_consumed", got.SessionID, got.DeviceID, map[string]any{"sid": q.SID})
	writeJSON(w, http.StatusOK, map[string]any{
		"status":               store.QRApproved,
		"session_token":        token,
		"session_id":           *got.SessionID,
		"kind":                 store.KindWeb,
		"idle_timeout_seconds": int(WebIdleTimeout / time.Second),
		"phone_eph_pub":        lcrypto.B64(got.PhoneEphPub),
		"nonce":                lcrypto.B64(got.Nonce),
		"ciphertext":           lcrypto.B64(got.Ciphertext),
	})
}

// handleQRDetails shows the phone what it is about to approve.
func (s *Server) handleQRDetails(w http.ResponseWriter, r *http.Request, _ *store.Session) {
	q, sid, ok := s.loadQR(w, r)
	if !ok {
		return
	}
	code, _ := lcrypto.VerifyCode(sid, q.BrowserPub)
	writeJSON(w, http.StatusOK, map[string]any{
		"sid":         q.SID,
		"status":      effectiveStatus(q, s.now()),
		"browser_pub": lcrypto.B64(q.BrowserPub),
		"client_info": q.ClientInfo,
		"ip":          q.IP,
		"created_at":  q.CreatedAt,
		"expires_at":  q.ExpiresAt,
		"verify_code": code,
	})
}

type qrApproveRequest struct {
	PhoneEphPub string `json:"phone_eph_pub"`
	Nonce       string `json:"nonce"`
	Ciphertext  string `json:"ciphertext"`
	Signature   string `json:"signature"`
}

// handleQRApprove verifies the phone's signature over the canonical approval
// message and, if the request is still pending, creates the web session.
func (s *Server) handleQRApprove(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	q, sid, ok := s.loadQR(w, r)
	if !ok {
		return
	}
	var req qrApproveRequest
	if !readJSON(w, r, &req) {
		return
	}
	phonePub, ok := b64field(w, "phone_eph_pub", req.PhoneEphPub, lcrypto.X25519KeySize)
	if !ok {
		return
	}
	nonce, ok := b64field(w, "nonce", req.Nonce, lcrypto.NonceSize)
	if !ok {
		return
	}
	ct, ok := b64field(w, "ciphertext", req.Ciphertext, lcrypto.QRCiphertextSize)
	if !ok {
		return
	}
	sig, ok := b64field(w, "signature", req.Signature, 64)
	if !ok {
		return
	}
	if sess.DeviceID == nil {
		writeError(w, http.StatusForbidden, "mobile_only", "this endpoint requires a mobile session")
		return
	}
	dev, err := s.st.GetDevice(r.Context(), *sess.DeviceID)
	if err != nil && !errors.Is(err, store.ErrNotFound) {
		s.internal(w, r, err)
		return
	}
	if err != nil || dev.RevokedAt != nil {
		writeError(w, http.StatusUnauthorized, "device_revoked", "device is not registered")
		return
	}
	// The message is rebuilt from the server's own copy of sid and
	// browser_pub, so a signature made for another request cannot be reused.
	msg, err := lcrypto.QRApproveMessage(sid, q.BrowserPub, phonePub, nonce, ct)
	if err != nil || !lcrypto.Ed25519Verify(dev.Ed25519Pub, msg, sig) {
		s.audit(r, "qr_approve_failed", &sess.ID, &dev.ID, map[string]any{"sid": q.SID, "reason": "bad_signature"})
		writeError(w, http.StatusForbidden, "bad_signature", "approval signature is not valid for this request")
		return
	}
	now := s.now()
	pending := store.Session{
		ID: lcrypto.NewUUID(), Kind: store.KindWeb, DeviceID: &dev.ID, ClientInfo: q.ClientInfo, IP: q.IP,
		CreatedAt: now, LastSeen: now, IdleTimeoutSeconds: int(WebIdleTimeout / time.Second),
	}
	appr := store.QRApproval{PhoneEphPub: phonePub, Nonce: nonce, Ciphertext: ct, Signature: sig, DeviceID: dev.ID}
	switch err := s.st.ApproveQR(r.Context(), q.SID, appr, pending, now); {
	case errors.Is(err, store.ErrQRExpired):
		writeError(w, http.StatusGone, "qr_expired", "the QR request has expired")
		return
	case errors.Is(err, store.ErrQRState):
		writeError(w, http.StatusConflict, "qr_not_pending", "the QR request has already been answered")
		return
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "qr_not_found", "unknown QR request")
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	s.audit(r, "qr_approved", &sess.ID, &dev.ID, map[string]any{"sid": q.SID, "web_session_id": pending.ID, "browser_ip": q.IP})
	writeJSON(w, http.StatusOK, map[string]any{"status": store.QRApproved, "session_id": pending.ID})
}

func (s *Server) handleQRReject(w http.ResponseWriter, r *http.Request, sess *store.Session) {
	q, _, ok := s.loadQR(w, r)
	if !ok {
		return
	}
	now := s.now()
	if effectiveStatus(q, now) == store.QRExpired {
		writeError(w, http.StatusGone, "qr_expired", "the QR request has expired")
		return
	}
	switch err := s.st.RejectQR(r.Context(), q.SID, now); {
	case errors.Is(err, store.ErrQRState):
		writeError(w, http.StatusConflict, "qr_not_pending", "the QR request has already been answered")
		return
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, "qr_not_found", "unknown QR request")
		return
	case err != nil:
		s.internal(w, r, err)
		return
	}
	s.audit(r, "qr_rejected", &sess.ID, sess.DeviceID, map[string]any{"sid": q.SID, "browser_ip": q.IP})
	writeJSON(w, http.StatusOK, map[string]any{"status": store.QRRejected})
}
