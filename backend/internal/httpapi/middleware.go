package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"runtime/debug"
	"strconv"
	"strings"
	"time"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
)

func itoa(n int) string { return strconv.Itoa(n) }

// ---- request-scoped log fields ----

type ctxKey struct{}

type reqInfo struct {
	route     string
	sessionID string
}

func info(r *http.Request) *reqInfo {
	if ri, ok := r.Context().Value(ctxKey{}).(*reqInfo); ok {
		return ri
	}
	return &reqInfo{}
}

func setRoute(r *http.Request, p string)    { info(r).route = p }
func setSession(r *http.Request, id string) { info(r).sessionID = id }
func routeOf(r *http.Request) string        { return info(r).route }

type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	if w.status == 0 {
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.ResponseWriter.Write(b)
}

// logging emits one JSON line per request. It records the route pattern, not
// the raw URL, and never logs headers or bodies, so tokens and ciphertext
// stay out of the logs.
func (s *Server) logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ri := &reqInfo{}
		r = r.WithContext(context.WithValue(r.Context(), ctxKey{}, ri))
		rid := lcrypto.B64(lcrypto.RandomBytes(9))
		w.Header().Set("X-Request-Id", rid)
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		if ri.route == "GET /healthz" && sw.status == http.StatusOK {
			return
		}
		attrs := []any{"request_id", rid, "method", r.Method, "route", ri.route, "status", sw.status,
			"duration_ms", time.Since(start).Milliseconds(), "ip", s.clientIP(r)}
		if ri.sessionID != "" {
			attrs = append(attrs, "session_id", ri.sessionID)
		}
		s.log.Info("request", attrs...)
	})
}

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if v := recover(); v != nil {
				if v == http.ErrAbortHandler {
					panic(v)
				}
				s.log.Error("panic", "panic", v, "stack", string(debug.Stack()))
				writeError(w, http.StatusInternalServerError, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// securityHeaders sets strict headers appropriate for a JSON-only API.
func (s *Server) securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Strict-Transport-Security", "max-age=63072000; includeSubDomains")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		h.Set("Cross-Origin-Resource-Policy", "same-site")
		h.Set("Permissions-Policy", "interest-cohort=()")
		next.ServeHTTP(w, r)
	})
}

const (
	corsAllowMethods = "GET, POST, PUT, DELETE, OPTIONS"
	corsAllowHeaders = "Authorization, Content-Type, X-Leopard-Poll-Token"
	corsExpose       = "Retry-After, X-Request-Id"
)

// cors implements an exact-match origin allowlist. Requests that carry an
// Origin header that is not on the list are refused outright: the only
// legitimate browser client is the Leopard web app, and native clients do
// not send Origin. Credentials (cookies) are never allowed; sessions use
// bearer tokens.
func (s *Server) cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin == "" {
			next.ServeHTTP(w, r)
			return
		}
		w.Header().Add("Vary", "Origin")
		if !s.origins[origin] {
			setRoute(r, "cors-denied")
			writeError(w, http.StatusForbidden, "origin_not_allowed", "origin not allowed")
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Access-Control-Expose-Headers", corsExpose)
		if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
			setRoute(r, "cors-preflight")
			w.Header().Set("Access-Control-Allow-Methods", corsAllowMethods)
			w.Header().Set("Access-Control-Allow-Headers", corsAllowHeaders)
			w.Header().Set("Access-Control-Max-Age", "600")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// clientIP returns the peer address, or, when the service is configured to
// trust N proxy hops, the N-th address from the right of X-Forwarded-For.
// Counting from the right matters: everything to the left of the entries
// appended by trusted proxies is client-controlled.
func (s *Server) clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if s.hops > 0 {
		parts := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
		if i := len(parts) - s.hops; i >= 0 {
			if a, err := netip.ParseAddr(strings.TrimSpace(parts[i])); err == nil {
				return a.Unmap().String()
			}
		}
	}
	if a, err := netip.ParseAddr(host); err == nil {
		return a.Unmap().String()
	}
	return host
}

// rateKey groups IPv6 clients by /64, since one subscriber controls a whole /64.
func rateKey(ip string) string {
	a, err := netip.ParseAddr(ip)
	if err != nil || a.Is4() {
		return ip
	}
	p, err := a.Prefix(64)
	if err != nil {
		return ip
	}
	return p.String()
}

// ---- JSON helpers ----

type errorBody struct {
	Error struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	var b errorBody
	b.Error.Code, b.Error.Message = code, msg
	writeJSON(w, status, b)
}

// readJSON decodes a JSON object body into v, writing the error response
// itself on failure. Unknown fields and trailing data are rejected.
func readJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	mt, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mt != "application/json" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "Content-Type must be application/json")
		return false
	}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			writeError(w, http.StatusRequestEntityTooLarge, "body_too_large", "request body too large")
			return false
		}
		writeError(w, http.StatusBadRequest, "invalid_json", "malformed JSON body")
		return false
	}
	if _, err := dec.Token(); err != io.EOF {
		writeError(w, http.StatusBadRequest, "invalid_json", "unexpected data after JSON body")
		return false
	}
	return true
}

func badRequest(w http.ResponseWriter, msg string) {
	writeError(w, http.StatusBadRequest, "invalid_request", msg)
}

// b64field decodes a base64url field of an exact size (size < 0: any).
func b64field(w http.ResponseWriter, name, val string, size int) ([]byte, bool) {
	b, err := lcrypto.UnB64(val)
	if err != nil || val == "" {
		badRequest(w, name+" must be base64url without padding")
		return nil, false
	}
	if size >= 0 && len(b) != size {
		badRequest(w, name+" must be "+itoa(size)+" bytes")
		return nil, false
	}
	return b, true
}
