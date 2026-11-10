// Package httpapi is the Leopard HTTP API.
//
// The server is zero-knowledge with respect to vault contents: it stores and
// relays ciphertext, verifies signatures and proofs, and manages sessions. It
// never receives the vault key, the master password or item plaintext.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/leopard-vault/leopard/backend/internal/auth"
	"github.com/leopard-vault/leopard/backend/internal/ratelimit"
	"github.com/leopard-vault/leopard/backend/internal/store"
)

// Protocol timings.
const (
	QRLifetime         = 60 * time.Second // a QR request can be approved for this long
	QRCollectWindow    = 60 * time.Second // an approval must be collected by the browser within this
	ChallengeLifetime  = 60 * time.Second
	WebIdleTimeout     = 300 * time.Second
	WebMaxLifetime     = 12 * time.Hour // absolute cap for a web session, heartbeat or not
	MobileIdleTimeout  = 24 * time.Hour // the phone re-authenticates silently with its device key
	mobileTouchEvery   = 30 * time.Second
	CleanupInterval    = time.Minute
	maxBodyDefault     = 16 << 10
	maxBodyItem        = 512 << 10
	MaxItemCiphertext  = 256 << 10
	maxClientInfoBytes = 2 << 10
	maxLabelLen        = 64
)

// Rate-limit rules. Buckets are per client IP unless the name says global.
var (
	ruleDefault      = ratelimit.Rule{Name: "default", Burst: 120, Per: time.Minute}
	ruleSetup        = ratelimit.Rule{Name: "setup", Burst: 5, Per: time.Hour}
	ruleDeviceAuth   = ratelimit.Rule{Name: "device-auth", Burst: 20, Per: time.Minute}
	ruleQRCreate     = ratelimit.Rule{Name: "qr-create", Burst: 10, Per: time.Minute}
	ruleQRPoll       = ratelimit.Rule{Name: "qr-poll", Burst: 90, Per: time.Minute}
	ruleMasterParams = ratelimit.Rule{Name: "master-params", Burst: 5, Per: 5 * time.Minute}
	ruleMasterLogin  = ratelimit.Rule{Name: "master-login", Burst: 5, Per: 15 * time.Minute}
	ruleRecovery     = ratelimit.Rule{Name: "recovery", Burst: 5, Per: time.Hour}
	// Global ceilings on password/recovery guessing regardless of source IP.
	ruleMasterLoginGlobal = ratelimit.Rule{Name: "master-login-global", Burst: 10, Per: 15 * time.Minute}
	ruleRecoveryGlobal    = ratelimit.Rule{Name: "recovery-global", Burst: 10, Per: time.Hour}
)

// Options configures a Server.
type Options struct {
	Store            store.Store
	ServerKey        []byte
	WebOrigins       []string
	TrustedProxyHops int
	SetupToken       string
	Logger           *slog.Logger
	// Now is the clock; nil means time.Now. Tests inject a fake.
	Now func() time.Time
}

// Server implements http.Handler.
type Server struct {
	st      store.Store
	box     *auth.SecretBox
	lim     *ratelimit.Limiter
	log     *slog.Logger
	clock   func() time.Time
	origins map[string]bool
	hops    int
	setup   string
	handler http.Handler
}

// New builds the API handler.
func New(o Options) (*Server, error) {
	if o.Store == nil {
		return nil, errors.New("httpapi: store is required")
	}
	box, err := auth.NewSecretBox(o.ServerKey)
	if err != nil {
		return nil, err
	}
	if o.Logger == nil {
		o.Logger = slog.New(slog.DiscardHandler)
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	s := &Server{
		st: o.Store, box: box, log: o.Logger, clock: o.Now,
		lim: ratelimit.New(o.Now), origins: map[string]bool{}, hops: o.TrustedProxyHops, setup: o.SetupToken,
	}
	for _, or := range o.WebOrigins {
		s.origins[or] = true
	}
	s.handler = s.routes()
	return s, nil
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) { s.handler.ServeHTTP(w, r) }

// now returns the current time in UTC, truncated to the microsecond
// resolution Postgres stores, so values round-trip exactly.
func (s *Server) now() time.Time { return s.clock().UTC().Truncate(time.Microsecond) }

type authMode int

const (
	authNone   authMode = iota
	authAny             // any live session
	authMobile          // a live mobile session
)

type route struct {
	pattern string
	rule    ratelimit.Rule
	auth    authMode
	maxBody int64
	h       func(w http.ResponseWriter, r *http.Request, sess *store.Session)
}

func (s *Server) routes() http.Handler {
	rs := []route{
		{"GET /healthz", ruleDefault, authNone, 0, s.handleHealthz},
		{"POST /v1/setup", ruleSetup, authNone, 0, s.handleSetup},

		{"POST /v1/auth/device/challenge", ruleDeviceAuth, authNone, 0, s.handleDeviceChallenge},
		{"POST /v1/auth/device/verify", ruleDeviceAuth, authNone, 0, s.handleDeviceVerify},
		{"GET /v1/auth/master/params", ruleMasterParams, authNone, 0, s.handleMasterParams},
		{"POST /v1/auth/master/login", ruleMasterLogin, authNone, 0, s.handleMasterLogin},
		{"POST /v1/recovery/register-device", ruleRecovery, authNone, 0, s.handleRecovery},

		{"POST /v1/qr", ruleQRCreate, authNone, 0, s.handleQRCreate},
		{"GET /v1/qr/{sid}", ruleQRPoll, authNone, 0, s.handleQRPoll},
		{"GET /v1/qr/{sid}/details", ruleDefault, authMobile, 0, s.handleQRDetails},
		{"POST /v1/qr/{sid}/approve", ruleDefault, authMobile, 0, s.handleQRApprove},
		{"POST /v1/qr/{sid}/reject", ruleDefault, authMobile, 0, s.handleQRReject},

		{"GET /v1/items", ruleDefault, authAny, 0, s.handleItemsList},
		{"PUT /v1/items/{id}", ruleDefault, authAny, maxBodyItem, s.handleItemPut},
		{"DELETE /v1/items/{id}", ruleDefault, authAny, 0, s.handleItemDelete},

		{"POST /v1/sessions/heartbeat", ruleDefault, authAny, 0, s.handleHeartbeat},
		{"POST /v1/sessions/logout", ruleDefault, authAny, 0, s.handleLogout},
		{"GET /v1/sessions", ruleDefault, authMobile, 0, s.handleSessionsList},
		{"DELETE /v1/sessions/{id}", ruleDefault, authMobile, 0, s.handleSessionRevoke},

		{"GET /v1/audit", ruleDefault, authMobile, 0, s.handleAudit},
	}
	mux := http.NewServeMux()
	for _, rt := range rs {
		mux.Handle(rt.pattern, s.wrap(rt))
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not_found", "no such endpoint")
	})
	return s.recoverer(s.logging(s.securityHeaders(s.cors(mux))))
}

// wrap applies rate limiting, the body limit and authentication to a route.
func (s *Server) wrap(rt route) http.Handler {
	limit := rt.maxBody
	if limit == 0 {
		limit = maxBodyDefault
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		setRoute(r, rt.pattern)
		if !s.allow(w, rt.rule, rateKey(s.clientIP(r))) {
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, limit)
		var sess *store.Session
		if rt.auth != authNone {
			var ok bool
			if sess, ok = s.authenticate(w, r); !ok {
				return
			}
			if rt.auth == authMobile && sess.Kind != store.KindMobile {
				writeError(w, http.StatusForbidden, "mobile_only", "this endpoint requires a mobile session")
				return
			}
			setSession(r, sess.ID)
		}
		rt.h(w, r, sess)
	})
}

// allow consumes a token and writes a 429 if none is left.
func (s *Server) allow(w http.ResponseWriter, rule ratelimit.Rule, key string) bool {
	ok, retry := s.lim.Allow(rule, key)
	if ok {
		return true
	}
	secs := int(retry/time.Second) + 1
	w.Header().Set("Retry-After", itoa(secs))
	writeError(w, http.StatusTooManyRequests, "rate_limited", "too many requests; retry later")
	return false
}

// authenticate resolves the bearer token to a live session. Idle and
// over-age sessions are revoked on the spot so they can never come back.
func (s *Server) authenticate(w http.ResponseWriter, r *http.Request) (*store.Session, bool) {
	deny := func(code, msg string) (*store.Session, bool) {
		w.Header().Set("WWW-Authenticate", `Bearer realm="leopard"`)
		writeError(w, http.StatusUnauthorized, code, msg)
		return nil, false
	}
	tok, ok := auth.BearerToken(r)
	if !ok {
		return deny("unauthenticated", "missing bearer token")
	}
	hash, ok := auth.HashToken(tok)
	if !ok {
		return deny("invalid_token", "invalid session token")
	}
	sess, err := s.st.GetSessionByTokenHash(r.Context(), hash)
	if errors.Is(err, store.ErrNotFound) {
		return deny("invalid_token", "invalid session token")
	}
	if err != nil {
		s.internal(w, r, err)
		return nil, false
	}
	now := s.now()
	if sess.RevokedAt != nil {
		return deny("session_revoked", "session has been revoked")
	}
	idle := time.Duration(sess.IdleTimeoutSeconds) * time.Second
	if now.Sub(sess.LastSeen) > idle || (sess.Kind == store.KindWeb && now.Sub(sess.CreatedAt) > WebMaxLifetime) {
		if _, err := s.st.RevokeSession(r.Context(), sess.ID, now); err != nil {
			s.internal(w, r, err)
			return nil, false
		}
		s.audit(r, "session_expired", &sess.ID, sess.DeviceID, nil)
		return deny("session_expired", "session expired")
	}
	// Web sessions stay alive only through explicit heartbeats, so background
	// requests cannot defeat the idle lock. Mobile sessions slide on use.
	if sess.Kind == store.KindMobile && now.Sub(sess.LastSeen) >= mobileTouchEvery {
		if err := s.st.TouchSession(r.Context(), sess.ID, now); err != nil {
			s.internal(w, r, err)
			return nil, false
		}
		sess.LastSeen = now
	}
	return sess, true
}

// audit appends to the audit log. Failures are logged, not surfaced: by the
// time an event is recorded the action has already happened.
func (s *Server) audit(r *http.Request, event string, sessionID, deviceID *string, meta map[string]any) {
	var raw json.RawMessage
	if len(meta) > 0 {
		raw, _ = json.Marshal(meta)
	}
	e := store.AuditEntry{TS: s.now(), Event: event, SessionID: sessionID, DeviceID: deviceID, IP: s.clientIP(r), Meta: raw}
	if err := s.st.AppendAudit(context.WithoutCancel(r.Context()), e); err != nil {
		s.log.Error("audit append failed", "event", event, "err", err.Error())
	}
}

// internal logs err and returns a generic 500. Error details never reach the client.
func (s *Server) internal(w http.ResponseWriter, r *http.Request, err error) {
	s.log.Error("internal error", "route", routeOf(r), "err", err.Error())
	writeError(w, http.StatusInternalServerError, "internal", "internal error")
}

// RunCleanup periodically expires QR requests, challenges and idle sessions
// and sweeps the rate limiter until ctx is cancelled.
func (s *Server) RunCleanup(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			s.CleanupOnce(ctx)
		}
	}
}

// CleanupOnce runs a single cleanup pass.
func (s *Server) CleanupOnce(ctx context.Context) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	st, err := s.st.Cleanup(cctx, s.now())
	if err != nil {
		s.log.Error("cleanup failed", "err", err.Error())
		return
	}
	swept := s.lim.Sweep()
	if st != (store.CleanupStats{}) || swept > 0 {
		s.log.Info("cleanup", "qr_expired", st.QRExpired, "qr_deleted", st.QRDeleted, "challenges_deleted", st.ChallengesDeleted,
			"sessions_revoked", st.SessionsRevoked, "sessions_deleted", st.SessionsDeleted, "rate_buckets_swept", swept)
	}
}
