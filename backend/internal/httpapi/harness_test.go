package httpapi

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/migrations"
	"github.com/leopard-vault/leopard/backend/internal/store"
	"github.com/leopard-vault/leopard/backend/internal/totp"
)

// ---- fake clock ----

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// ---- test environment ----

type env struct {
	t    *testing.T
	srv  *Server
	clk  *fakeClock
	st   store.Store
	logs *syncBuffer
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

const testOrigin = "https://leopard.example"

func newEnv(t *testing.T, mut ...func(*Options)) *env {
	return newEnvWithStore(t, store.NewMem(), mut...)
}

func newEnvWithStore(t *testing.T, st store.Store, mut ...func(*Options)) *env {
	t.Helper()
	clk := &fakeClock{t: time.Date(2026, 11, 11, 10, 0, 0, 0, time.UTC)}
	logs := &syncBuffer{}
	o := Options{
		Store: st, ServerKey: lcrypto.RandomBytes(32), WebOrigins: []string{testOrigin},
		Logger: slog.New(slog.NewJSONHandler(logs, nil)), Now: clk.Now,
	}
	for _, m := range mut {
		m(&o)
	}
	srv, err := New(o)
	if err != nil {
		t.Fatal(err)
	}
	return &env{t: t, srv: srv, clk: clk, st: st, logs: logs}
}

// openTestPG returns a Postgres store in a private schema, or skips.
func openTestPG(t *testing.T) store.Store {
	t.Helper()
	url := os.Getenv("LEOPARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("LEOPARD_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	admin, err := store.OpenPG(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	// A private schema keeps this package independent of the store package's
	// tests, which run concurrently against the public schema.
	if _, err := admin.Pool().Exec(ctx, `DROP SCHEMA IF EXISTS httpapi_test CASCADE; CREATE SCHEMA httpapi_test`); err != nil {
		t.Fatal(err)
	}
	admin.Close()
	sep := "?"
	if strings.Contains(url, "?") {
		sep = "&"
	}
	pg, err := store.OpenPG(ctx, url+sep+"search_path=httpapi_test")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := migrations.Up(ctx, pg.Pool()); err != nil {
		t.Fatal(err)
	}
	return pg
}

type resp struct {
	status int
	header http.Header
	body   map[string]any
	raw    string
}

func (r resp) str(k string) string {
	s, _ := r.body[k].(string)
	return s
}

func (r resp) errCode() string {
	e, _ := r.body["error"].(map[string]any)
	c, _ := e["code"].(string)
	return c
}

type reqOpt func(*http.Request)

func bearer(tok string) reqOpt {
	return func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+tok) }
}

func header(k, v string) reqOpt { return func(r *http.Request) { r.Header.Set(k, v) } }

func fromIP(ip string) reqOpt { return func(r *http.Request) { r.RemoteAddr = ip + ":40000" } }

// do sends a request. body may be nil, a string (sent verbatim) or any JSON-able value.
func (e *env) do(method, path string, body any, opts ...reqOpt) resp {
	e.t.Helper()
	var rd io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		rd = strings.NewReader(b)
	default:
		j, err := json.Marshal(b)
		if err != nil {
			e.t.Fatal(err)
		}
		rd = bytes.NewReader(j)
	}
	r := httptest.NewRequest(method, path, rd)
	if body != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	for _, o := range opts {
		o(r)
	}
	w := httptest.NewRecorder()
	e.srv.ServeHTTP(w, r)
	out := resp{status: w.Code, header: w.Header(), raw: w.Body.String()}
	if w.Body.Len() > 0 {
		_ = json.Unmarshal(w.Body.Bytes(), &out.body)
	}
	return out
}

func (e *env) want(r resp, status int) resp {
	e.t.Helper()
	if r.status != status {
		e.t.Fatalf("status %d, want %d; body: %s", r.status, status, r.raw)
	}
	return r
}

func (e *env) wantErr(r resp, status int, code string) {
	e.t.Helper()
	if r.status != status || r.errCode() != code {
		e.t.Fatalf("got %d %q, want %d %q; body: %s", r.status, r.errCode(), status, code, r.raw)
	}
}

// ---- a simulated phone doing the real client-side cryptography ----

const testPassword = "correct horse battery staple"

// Argon2id at production cost takes a noticeable fraction of a second, so the
// master-password material is derived once for the whole test binary.
var master = sync.OnceValue(func() (m struct{ salt, kek, authKey []byte }) {
	m.salt = lcrypto.RandomBytes(16)
	var err error
	if m.kek, err = lcrypto.DeriveKEK([]byte(testPassword), m.salt, lcrypto.DefaultKDFParams()); err != nil {
		panic(err)
	}
	m.authKey, _ = lcrypto.MasterAuthKey(m.kek)
	return m
})

type phone struct {
	e          *env
	priv       ed25519.PrivateKey
	pub        ed25519.PublicKey
	vk         []byte
	rk         []byte
	totpSecret []byte
	deviceID   string
	token      string
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func (e *env) setupBody(p *phone) map[string]any {
	m := master()
	rkKEK := must(lcrypto.RecoveryKEK(p.rk))
	return map[string]any{
		"kdf_params":             lcrypto.DefaultKDFParams(),
		"salt":                   lcrypto.B64(m.salt),
		"wrapped_vk_master":      lcrypto.B64(must(lcrypto.WrapVK(m.kek, lcrypto.RandomBytes(12), p.vk, lcrypto.InfoWrapMaster))),
		"wrapped_vk_recovery":    lcrypto.B64(must(lcrypto.WrapVK(rkKEK, lcrypto.RandomBytes(12), p.vk, lcrypto.InfoWrapRecovery))),
		"master_auth_verifier":   lcrypto.B64(lcrypto.AuthVerifier(m.authKey)),
		"recovery_auth_verifier": lcrypto.B64(lcrypto.AuthVerifier(must(lcrypto.RecoveryAuthKey(p.rk)))),
		"totp_secret":            lcrypto.B64(p.totpSecret),
		"device":                 map[string]any{"label": "Pixel 9", "ed25519_pub": lcrypto.B64(p.pub)},
	}
}

func newPhone(e *env) *phone {
	pub, priv, _ := ed25519.GenerateKey(nil)
	return &phone{e: e, priv: priv, pub: pub, vk: lcrypto.RandomBytes(32), rk: lcrypto.RandomBytes(16), totpSecret: lcrypto.RandomBytes(20)}
}

// setupVault initialises the vault from a fresh phone and logs the phone in.
func (e *env) setupVault() *phone {
	e.t.Helper()
	p := newPhone(e)
	r := e.want(e.do("POST", "/v1/setup", e.setupBody(p)), http.StatusCreated)
	p.deviceID = r.str("device_id")
	p.login()
	return p
}

// login runs the device challenge-response and stores the session token.
func (p *phone) login() {
	p.e.t.Helper()
	r := p.tryLogin()
	p.e.want(r, http.StatusOK)
	p.token = r.str("session_token")
	if r.str("kind") != "mobile" || len(p.token) != 43 {
		p.e.t.Fatalf("unexpected grant: %s", r.raw)
	}
}

func (p *phone) tryLogin() resp {
	e := p.e
	ch := e.want(e.do("POST", "/v1/auth/device/challenge", map[string]any{"device_id": p.deviceID}), http.StatusOK)
	nonce := must(lcrypto.UnB64(ch.str("nonce")))
	sig := ed25519.Sign(p.priv, must(lcrypto.DeviceAuthMessage(p.deviceID, nonce)))
	return e.do("POST", "/v1/auth/device/verify", map[string]any{
		"device_id": p.deviceID, "nonce": ch.str("nonce"), "signature": lcrypto.B64(sig)})
}

func (p *phone) auth() reqOpt { return bearer(p.token) }

// approvalBody performs the phone side of the QR key transfer.
func (p *phone) approvalBody(sidB64 string, browserPub []byte) map[string]any {
	sid := must(lcrypto.UnB64(sidB64))
	ephPriv := lcrypto.RandomBytes(32)
	ephPub := must(lcrypto.X25519Public(ephPriv))
	nonce := lcrypto.RandomBytes(12)
	ct := must(lcrypto.QRSealVK(ephPriv, browserPub, sid, nonce, p.vk))
	sig := ed25519.Sign(p.priv, must(lcrypto.QRApproveMessage(sid, browserPub, ephPub, nonce, ct)))
	return map[string]any{"phone_eph_pub": lcrypto.B64(ephPub), "nonce": lcrypto.B64(nonce),
		"ciphertext": lcrypto.B64(ct), "signature": lcrypto.B64(sig)}
}

func (p *phone) totpNow() string { return totp.Code(p.totpSecret, p.e.clk.Now()) }

// ---- a simulated browser ----

type browser struct {
	e         *env
	priv, pub []byte
	sid       string
	pollToken string
	token     string
	vk        []byte
}

func (e *env) newBrowser() *browser {
	e.t.Helper()
	b := &browser{e: e, priv: lcrypto.RandomBytes(32)}
	b.pub = must(lcrypto.X25519Public(b.priv))
	r := e.want(e.do("POST", "/v1/qr", map[string]any{
		"browser_pub": lcrypto.B64(b.pub), "client_info": map[string]any{"platform": "Linux", "browser": "Firefox"},
	}, header("User-Agent", "TestBrowser/1.0"), header("Origin", testOrigin)), http.StatusCreated)
	b.sid, b.pollToken = r.str("sid"), r.str("poll_token")
	return b
}

func (b *browser) poll() resp {
	return b.e.do("GET", "/v1/qr/"+b.sid, nil, header("X-Leopard-Poll-Token", b.pollToken), header("Origin", testOrigin))
}

// collect polls once and, if the login was approved, decrypts the vault key.
func (b *browser) collect() resp {
	b.e.t.Helper()
	r := b.poll()
	if r.str("status") == "approved" {
		vk, err := lcrypto.QROpenVK(b.priv, must(lcrypto.UnB64(r.str("phone_eph_pub"))), must(lcrypto.UnB64(b.sid)),
			must(lcrypto.UnB64(r.str("nonce"))), must(lcrypto.UnB64(r.str("ciphertext"))))
		if err != nil {
			b.e.t.Fatalf("browser could not decrypt the transferred key: %v", err)
		}
		b.vk, b.token = vk, r.str("session_token")
	}
	return r
}

func (b *browser) auth() reqOpt { return bearer(b.token) }

// loggedInBrowser runs a complete, approved QR login.
func (e *env) loggedInBrowser(p *phone) *browser {
	e.t.Helper()
	b := e.newBrowser()
	e.want(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), http.StatusOK)
	if r := b.collect(); r.str("status") != "approved" || b.token == "" {
		e.t.Fatalf("collect: %s", r.raw)
	}
	return b
}
