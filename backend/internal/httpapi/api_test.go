package httpapi

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/store"
	"github.com/leopard-vault/leopard/backend/internal/totp"
)

// qrEndToEnd is the whole happy path with real cryptography on both sides:
// the phone encrypts the vault key to the browser's ephemeral key, the server
// relays it without being able to read it, and the browser ends up with the
// same vault key and a working session.
func qrEndToEnd(t *testing.T, e *env) {
	p := e.setupVault()
	b := e.newBrowser()

	if r := b.poll(); r.status != 200 || r.str("status") != "pending" || r.body["session_token"] != nil {
		t.Fatalf("poll before approval: %s", r.raw)
	}

	// The phone inspects the request. The verification code must equal what
	// both sides compute locally from sid and the browser key.
	d := e.want(e.do("GET", "/v1/qr/"+b.sid+"/details", nil, p.auth()), 200)
	wantCode := must(lcrypto.VerifyCode(must(lcrypto.UnB64(b.sid)), b.pub))
	if d.str("verify_code") != wantCode || d.str("browser_pub") != lcrypto.B64(b.pub) || d.str("ip") != "192.0.2.1" || d.str("status") != "pending" {
		t.Fatalf("details: %s", d.raw)
	}
	ci, _ := d.body["client_info"].(map[string]any)
	if ci["user_agent"] != "TestBrowser/1.0" || ci["reported"].(map[string]any)["browser"] != "Firefox" {
		t.Fatalf("client_info: %v", ci)
	}

	a := e.want(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), 200)
	webSessionID := a.str("session_id")
	if a.str("status") != "approved" || !lcrypto.IsCanonicalUUID(webSessionID) {
		t.Fatalf("approve: %s", a.raw)
	}

	// Before the browser collects, the approved session must not be usable or listed.
	if s := e.want(e.do("GET", "/v1/sessions", nil, p.auth()), 200); len(s.body["sessions"].([]any)) != 1 {
		t.Fatalf("uncollected web session is listed: %s", s.raw)
	}

	r := b.collect()
	if r.str("status") != "approved" || r.str("session_id") != webSessionID || r.body["idle_timeout_seconds"] != float64(300) {
		t.Fatalf("collect: %s", r.raw)
	}
	if !bytes.Equal(b.vk, p.vk) {
		t.Fatal("browser derived a different vault key than the phone sent")
	}

	// One-time consumption: every later poll gets no token and no payload.
	for i := 0; i < 3; i++ {
		again := b.poll()
		if again.status != 200 || again.str("status") != "consumed" {
			t.Fatalf("second poll: %s", again.raw)
		}
		for _, k := range []string{"session_token", "ciphertext", "nonce", "phone_eph_pub"} {
			if _, present := again.body[k]; present {
				t.Fatalf("second poll leaked %s", k)
			}
		}
	}
	if a2 := e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()); a2.status != http.StatusConflict {
		t.Fatalf("approve after consumption: %d %s", a2.status, a2.raw)
	}

	// The web session works, and both sides can read each other's items.
	id := lcrypto.NewUUID()
	itemKey := must(lcrypto.DeriveItemKey(p.vk))
	nonce := lcrypto.RandomBytes(12)
	plain := []byte(`{"type":"login","title":"Mail","fields":{"password":"hunter2"}}`)
	ct := must(lcrypto.SealItem(itemKey, nonce, id, 1, plain))
	e.want(e.do("PUT", "/v1/items/"+id, map[string]any{"ciphertext": lcrypto.B64(ct), "nonce": lcrypto.B64(nonce), "expected_version": 0}, p.auth()), 201)

	list := e.want(e.do("GET", "/v1/items", nil, b.auth(), header("Origin", testOrigin)), 200)
	items := list.body["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("items: %s", list.raw)
	}
	it := items[0].(map[string]any)
	got, err := lcrypto.OpenItem(must(lcrypto.DeriveItemKey(b.vk)), must(lcrypto.UnB64(it["nonce"].(string))),
		it["id"].(string), uint64(it["version"].(float64)), must(lcrypto.UnB64(it["ciphertext"].(string))))
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("browser could not decrypt the phone's item: %v", err)
	}

	// The phone sees the new web session with the browser's details.
	s := e.want(e.do("GET", "/v1/sessions", nil, p.auth()), 200)
	sessions := s.body["sessions"].([]any)
	if len(sessions) != 2 {
		t.Fatalf("sessions: %s", s.raw)
	}
	var web map[string]any
	for _, x := range sessions {
		if m := x.(map[string]any); m["kind"] == "web" {
			web = m
		} else if m["current"] != true {
			t.Fatalf("mobile session not marked current: %v", m)
		}
	}
	if web == nil || web["id"] != webSessionID || web["ip"] != "192.0.2.1" || web["device_id"] != p.deviceID {
		t.Fatalf("web session: %v", web)
	}

	// Nothing the server stored or logged contains the vault key, plaintext or a token.
	audit := e.want(e.do("GET", "/v1/audit", nil, p.auth()), 200)
	for _, hay := range []string{audit.raw, e.logs.String()} {
		for name, needle := range map[string]string{
			"vault key": lcrypto.B64(p.vk), "session token": b.token, "phone token": p.token,
			"poll token": b.pollToken, "plaintext": "hunter2",
		} {
			if strings.Contains(hay, needle) {
				t.Fatalf("%s leaked into audit log or server log", name)
			}
		}
	}
	events := map[string]bool{}
	for _, x := range audit.body["entries"].([]any) {
		events[x.(map[string]any)["event"].(string)] = true
	}
	for _, ev := range []string{"vault_setup", "device_auth_ok", "qr_created", "qr_approved", "qr_consumed"} {
		if !events[ev] {
			t.Errorf("audit log is missing %q (have %v)", ev, events)
		}
	}
}

func TestQRFlowEndToEnd(t *testing.T) { qrEndToEnd(t, newEnv(t)) }

func TestQRFlowEndToEndPostgres(t *testing.T) { qrEndToEnd(t, newEnvWithStore(t, openTestPG(t))) }

func TestQRConcurrentPollsDeliverTokenOnce(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	b := e.newBrowser()
	e.want(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), 200)
	var wg sync.WaitGroup
	var mu sync.Mutex
	tokens := 0
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := b.poll()
			mu.Lock()
			defer mu.Unlock()
			if r.str("session_token") != "" {
				tokens++
			} else if r.str("status") != "consumed" {
				t.Errorf("loser saw %s", r.raw)
			}
		}()
	}
	wg.Wait()
	if tokens != 1 {
		t.Fatalf("%d polls received a session token, want exactly 1", tokens)
	}
}

func TestQRPollRequiresPollToken(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	b := e.newBrowser()
	e.want(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), 200)

	// Someone who only saw the QR code (sid + browser key) cannot collect.
	other := e.newBrowser()
	e.wantErr(e.do("GET", "/v1/qr/"+b.sid, nil), 404, "qr_not_found")
	e.wantErr(e.do("GET", "/v1/qr/"+b.sid, nil, header("X-Leopard-Poll-Token", other.pollToken)), 404, "qr_not_found")
	e.wantErr(e.do("GET", "/v1/qr/"+b.sid, nil, header("X-Leopard-Poll-Token", "garbage")), 404, "qr_not_found")
	e.wantErr(e.do("GET", "/v1/qr/"+lcrypto.B64(lcrypto.RandomBytes(16)), nil, header("X-Leopard-Poll-Token", b.pollToken)), 404, "qr_not_found")
	e.wantErr(e.do("GET", "/v1/qr/not-a-sid", nil, header("X-Leopard-Poll-Token", b.pollToken)), 404, "qr_not_found")
	// A phone session token is not a poll token either.
	e.wantErr(e.do("GET", "/v1/qr/"+b.sid, nil, p.auth()), 404, "qr_not_found")

	// The failed attempts did not burn the approval.
	if r := b.collect(); r.str("status") != "approved" || !bytes.Equal(b.vk, p.vk) {
		t.Fatalf("legitimate browser could not collect: %s", r.raw)
	}
}

func TestQRExpiry(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()

	// Not approved in time.
	b := e.newBrowser()
	e.clk.Advance(QRLifetime - time.Second)
	if r := b.poll(); r.str("status") != "pending" {
		t.Fatalf("at 59s: %s", r.raw)
	}
	e.clk.Advance(time.Second)
	if r := b.poll(); r.str("status") != "expired" {
		t.Fatalf("at 60s: %s", r.raw)
	}
	if d := e.want(e.do("GET", "/v1/qr/"+b.sid+"/details", nil, p.auth()), 200); d.str("status") != "expired" {
		t.Fatalf("details: %s", d.raw)
	}
	e.wantErr(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), 410, "qr_expired")
	e.wantErr(e.do("POST", "/v1/qr/"+b.sid+"/reject", nil, p.auth()), 410, "qr_expired")
	if r := b.poll(); r.str("status") != "expired" || r.body["session_token"] != nil {
		t.Fatalf("after late approve: %s", r.raw)
	}

	// Approved in time but collected too late: no token is ever issued.
	b2 := e.newBrowser()
	a := e.want(e.do("POST", "/v1/qr/"+b2.sid+"/approve", p.approvalBody(b2.sid, b2.pub), p.auth()), 200)
	e.clk.Advance(QRCollectWindow + time.Second)
	if r := b2.poll(); r.str("status") != "expired" || r.body["session_token"] != nil {
		t.Fatalf("late collect: %s", r.raw)
	}
	e.srv.CleanupOnce(context.Background())
	e.clk.Advance(10 * time.Minute)
	e.srv.CleanupOnce(context.Background())
	if _, err := e.st.GetSession(context.Background(), a.str("session_id")); err != store.ErrNotFound {
		t.Fatalf("never-collected session still stored: %v", err)
	}
	if q, _ := e.st.GetQR(context.Background(), b.sid); q.Status != store.QRExpired {
		t.Fatalf("cleanup did not mark the request expired: %s", q.Status)
	}
}

func TestQRBadSignature(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	b := e.newBrowser()
	path := "/v1/qr/" + b.sid + "/approve"

	// Signed by a key that is not the registered device key.
	evil := newPhone(e)
	evil.vk = p.vk
	e.wantErr(e.do("POST", path, evil.approvalBody(b.sid, b.pub), p.auth()), 403, "bad_signature")

	// A valid signature made for a different QR request.
	other := e.newBrowser()
	e.wantErr(e.do("POST", path, p.approvalBody(other.sid, other.pub), p.auth()), 403, "bad_signature")

	// A valid signature for this sid but a different browser key (a swapped QR code).
	e.wantErr(e.do("POST", path, p.approvalBody(b.sid, other.pub), p.auth()), 403, "bad_signature")

	// Each signed field, altered after signing.
	for _, field := range []string{"phone_eph_pub", "nonce", "ciphertext", "signature"} {
		body := p.approvalBody(b.sid, b.pub)
		raw := must(lcrypto.UnB64(body[field].(string)))
		raw[0] ^= 0x01
		body[field] = lcrypto.B64(raw)
		e.wantErr(e.do("POST", path, body, p.auth()), 403, "bad_signature")
	}

	// Malformed input is a 400, not a signature failure.
	body := p.approvalBody(b.sid, b.pub)
	body["signature"] = lcrypto.B64(make([]byte, 63))
	e.wantErr(e.do("POST", path, body, p.auth()), 400, "invalid_request")

	// None of that changed the request: it is still pending and no session exists.
	if r := b.poll(); r.str("status") != "pending" {
		t.Fatalf("request no longer pending: %s", r.raw)
	}
	if s := e.want(e.do("GET", "/v1/sessions", nil, p.auth()), 200); len(s.body["sessions"].([]any)) != 1 {
		t.Fatalf("a session was created: %s", s.raw)
	}
	// And a correct approval still succeeds.
	e.want(e.do("POST", path, p.approvalBody(b.sid, b.pub), p.auth()), 200)
	if r := b.collect(); !bytes.Equal(b.vk, p.vk) {
		t.Fatalf("collect: %s", r.raw)
	}
	audit := e.want(e.do("GET", "/v1/audit", nil, p.auth()), 200)
	if !strings.Contains(audit.raw, "qr_approve_failed") {
		t.Fatal("bad signatures were not audited")
	}
}

func TestQRRejectAndDoubleAnswer(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()

	b := e.newBrowser()
	if r := e.want(e.do("POST", "/v1/qr/"+b.sid+"/reject", nil, p.auth()), 200); r.str("status") != "rejected" {
		t.Fatalf("reject: %s", r.raw)
	}
	if r := b.poll(); r.str("status") != "rejected" || r.body["session_token"] != nil {
		t.Fatalf("poll: %s", r.raw)
	}
	e.wantErr(e.do("POST", "/v1/qr/"+b.sid+"/approve", p.approvalBody(b.sid, b.pub), p.auth()), 409, "qr_not_pending")
	e.wantErr(e.do("POST", "/v1/qr/"+b.sid+"/reject", nil, p.auth()), 409, "qr_not_pending")

	b2 := e.newBrowser()
	e.want(e.do("POST", "/v1/qr/"+b2.sid+"/approve", p.approvalBody(b2.sid, b2.pub), p.auth()), 200)
	e.wantErr(e.do("POST", "/v1/qr/"+b2.sid+"/approve", p.approvalBody(b2.sid, b2.pub), p.auth()), 409, "qr_not_pending")
	e.wantErr(e.do("POST", "/v1/qr/"+b2.sid+"/reject", nil, p.auth()), 409, "qr_not_pending")
}

func TestQRMobileOnlyEndpoints(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)
	b := e.newBrowser()

	// A web session must never be able to approve another login or manage sessions.
	for _, c := range []struct{ method, path string }{
		{"GET", "/v1/qr/" + b.sid + "/details"},
		{"POST", "/v1/qr/" + b.sid + "/approve"},
		{"POST", "/v1/qr/" + b.sid + "/reject"},
		{"GET", "/v1/sessions"},
		{"DELETE", "/v1/sessions/" + lcrypto.NewUUID()},
		{"GET", "/v1/audit"},
	} {
		e.wantErr(e.do(c.method, c.path, nil, web.auth()), 403, "mobile_only")
		e.wantErr(e.do(c.method, c.path, nil), 401, "unauthenticated")
		e.wantErr(e.do(c.method, c.path, nil, bearer(lcrypto.B64(lcrypto.RandomBytes(32)))), 401, "invalid_token")
	}
	if r := b.poll(); r.str("status") != "pending" {
		t.Fatalf("status changed: %s", r.raw)
	}
}

func TestQRCreateValidation(t *testing.T) {
	e := newEnv(t)
	e.wantErr(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 31))}), 400, "invalid_request")
	e.wantErr(e.do("POST", "/v1/qr", map[string]any{"browser_pub": "!!!"}), 400, "invalid_request")
	e.wantErr(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32)), "client_info": []int{1}}), 400, "invalid_request")
	big := map[string]any{"x": strings.Repeat("a", 3000)}
	e.wantErr(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32)), "client_info": big}), 400, "invalid_request")
	r := e.want(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32))}), 201)
	if !strings.HasPrefix(r.str("qr_uri"), "leopard://qr?v=1&sid="+r.str("sid")+"&pk=") || len(r.str("verify_code")) != 6 {
		t.Fatalf("create: %s", r.raw)
	}
}

// ---- sessions ----

func TestRevokeThenHeartbeat401(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)

	hb := e.want(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 200)
	sid := hb.str("session_id")

	// The phone revokes the browser session ("log out that computer").
	e.want(e.do("DELETE", "/v1/sessions/"+sid, nil, p.auth()), 200)
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 401, "session_revoked")
	e.wantErr(e.do("GET", "/v1/items", nil, web.auth()), 401, "session_revoked")
	e.wantErr(e.do("PUT", "/v1/items/"+lcrypto.NewUUID(), map[string]any{}, web.auth()), 401, "session_revoked")
	e.wantErr(e.do("DELETE", "/v1/sessions/"+sid, nil, p.auth()), 404, "session_not_found")
	e.wantErr(e.do("DELETE", "/v1/sessions/nope", nil, p.auth()), 400, "invalid_request")
	if s := e.want(e.do("GET", "/v1/sessions", nil, p.auth()), 200); len(s.body["sessions"].([]any)) != 1 {
		t.Fatalf("revoked session still listed: %s", s.raw)
	}

	// Logout revokes the caller's own session.
	web2 := e.loggedInBrowser(p)
	e.want(e.do("POST", "/v1/sessions/logout", nil, web2.auth()), 200)
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web2.auth()), 401, "session_revoked")
}

func TestWebSessionIdleTimeout(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)

	// Heartbeats keep it alive well past 300 s in total.
	for i := 0; i < 5; i++ {
		e.clk.Advance(200 * time.Second)
		e.want(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 200)
	}
	// Ordinary requests are allowed but do not count as activity...
	e.clk.Advance(200 * time.Second)
	e.want(e.do("GET", "/v1/items", nil, web.auth()), 200)
	e.clk.Advance(100 * time.Second)
	e.want(e.do("GET", "/v1/items", nil, web.auth()), 200) // exactly 300 s idle: still valid
	// ...so one second later the session is dead, permanently.
	e.clk.Advance(time.Second)
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 401, "session_expired")
	e.clk.Advance(-250 * time.Second) // even if the clock were wound back
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 401, "session_revoked")
}

func TestWebSessionAbsoluteLifetime(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)
	for elapsed := time.Duration(0); elapsed < WebMaxLifetime-4*time.Minute; elapsed += 4 * time.Minute {
		e.clk.Advance(4 * time.Minute)
		e.want(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 200)
	}
	e.clk.Advance(4*time.Minute + time.Second)
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 401, "session_expired")
}

func TestMobileSessionSlidesAndExpires(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	for i := 0; i < 3; i++ {
		e.clk.Advance(MobileIdleTimeout - time.Hour)
		e.want(e.do("GET", "/v1/items", nil, p.auth()), 200)
	}
	e.clk.Advance(MobileIdleTimeout + time.Second)
	e.wantErr(e.do("GET", "/v1/items", nil, p.auth()), 401, "session_expired")
	p.login() // the device key gets a fresh session
	e.want(e.do("GET", "/v1/items", nil, p.auth()), 200)
}

func TestCleanupRevokesIdleSessions(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)
	e.clk.Advance(WebIdleTimeout + time.Second)
	e.srv.CleanupOnce(context.Background())
	e.wantErr(e.do("GET", "/v1/items", nil, web.auth()), 401, "session_revoked")
	e.want(e.do("GET", "/v1/items", nil, p.auth()), 200)
}

// ---- items ----

func TestItemsOptimisticConcurrency(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	web := e.loggedInBrowser(p)
	id := lcrypto.NewUUID()
	path := "/v1/items/" + id
	put := func(ver int64, who reqOpt) resp {
		return e.do("PUT", path, map[string]any{
			"ciphertext": lcrypto.B64(lcrypto.RandomBytes(40)), "nonce": lcrypto.B64(lcrypto.RandomBytes(12)), "expected_version": ver}, who)
	}

	e.wantErr(put(1, p.auth()), 404, "item_not_found")
	if r := e.want(put(0, p.auth()), 201); r.body["version"] != float64(1) {
		t.Fatalf("create: %s", r.raw)
	}
	// Creating again must not overwrite.
	c := put(0, web.auth())
	e.wantErr(c, 409, "version_conflict")
	if cur := c.body["current"].(map[string]any); cur["version"] != float64(1) || cur["id"] != id {
		t.Fatalf("conflict body: %s", c.raw)
	}

	// Phone and browser both edit version 1; the second writer gets 409.
	e.clk.Advance(time.Second)
	if r := e.want(put(1, p.auth()), 200); r.body["version"] != float64(2) {
		t.Fatalf("update: %s", r.raw)
	}
	c = put(1, web.auth())
	e.wantErr(c, 409, "version_conflict")
	if c.body["current"].(map[string]any)["version"] != float64(2) {
		t.Fatalf("conflict body: %s", c.raw)
	}
	if strings.Contains(c.raw, "ciphertext") {
		t.Fatal("conflict response should not carry ciphertext")
	}
	// After re-reading, the browser's retry succeeds.
	e.clk.Advance(time.Second)
	e.want(put(2, web.auth()), 200)

	// Delete has the same protection.
	del := func(ver int64) resp { return e.do("DELETE", path, map[string]any{"expected_version": ver}, p.auth()) }
	e.wantErr(del(2), 409, "version_conflict")
	checkpoint := e.clk.Now()
	e.clk.Advance(time.Second)
	if r := e.want(del(3), 200); r.body["version"] != float64(4) || r.body["deleted"] != true {
		t.Fatalf("delete: %s", r.raw)
	}
	e.wantErr(del(4), 410, "item_deleted")
	e.wantErr(put(4, web.auth()), 410, "item_deleted")
	e.wantErr(put(0, web.auth()), 410, "item_deleted")
	e.wantErr(e.do("DELETE", "/v1/items/"+lcrypto.NewUUID(), map[string]any{"expected_version": 1}, p.auth()), 404, "item_not_found")

	// Delta sync delivers the tombstone, without ciphertext.
	l := e.want(e.do("GET", "/v1/items?since="+checkpoint.Format(time.RFC3339Nano), nil, web.auth()), 200)
	items := l.body["items"].([]any)
	if len(items) != 1 {
		t.Fatalf("delta: %s", l.raw)
	}
	tomb := items[0].(map[string]any)
	if tomb["deleted"] != true || tomb["version"] != float64(4) || tomb["ciphertext"] != nil || tomb["deleted_at"] == nil {
		t.Fatalf("tombstone: %v", tomb)
	}
	// Using the returned server_time as the next cursor yields nothing new.
	l2 := e.want(e.do("GET", "/v1/items?since="+l.str("server_time"), nil, web.auth()), 200)
	if len(l2.body["items"].([]any)) != 0 {
		t.Fatalf("second delta: %s", l2.raw)
	}
}

func TestItemsValidation(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	id := lcrypto.NewUUID()
	ct, n := lcrypto.B64(lcrypto.RandomBytes(40)), lcrypto.B64(lcrypto.RandomBytes(12))
	bad := []struct {
		path string
		body map[string]any
	}{
		{"/v1/items/not-a-uuid", map[string]any{"ciphertext": ct, "nonce": n, "expected_version": 0}},
		{"/v1/items/" + strings.ToUpper(id), map[string]any{"ciphertext": ct, "nonce": n, "expected_version": 0}},
		{"/v1/items/" + id, map[string]any{"ciphertext": ct, "nonce": n}},
		{"/v1/items/" + id, map[string]any{"ciphertext": ct, "nonce": n, "expected_version": -1}},
		{"/v1/items/" + id, map[string]any{"ciphertext": ct, "nonce": lcrypto.B64(make([]byte, 11)), "expected_version": 0}},
		{"/v1/items/" + id, map[string]any{"ciphertext": lcrypto.B64(make([]byte, 16)), "nonce": n, "expected_version": 0}},
		{"/v1/items/" + id, map[string]any{"ciphertext": "", "nonce": n, "expected_version": 0}},
		{"/v1/items/" + id, map[string]any{"ciphertext": ct + "=", "nonce": n, "expected_version": 0}},
		{"/v1/items/" + id, map[string]any{"ciphertext": ct, "nonce": n, "expected_version": 0, "plaintext": "oops"}},
	}
	for i, c := range bad {
		if r := e.do("PUT", c.path, c.body, p.auth()); r.status != 400 {
			t.Errorf("case %d: %d %s", i, r.status, r.raw)
		}
	}
	e.wantErr(e.do("GET", "/v1/items?since=yesterday", nil, p.auth()), 400, "invalid_request")
	e.wantErr(e.do("DELETE", "/v1/items/"+id, map[string]any{}, p.auth()), 400, "invalid_request")
	e.wantErr(e.do("GET", "/v1/items", nil), 401, "unauthenticated")

	// Size limits: 256 KiB of ciphertext is accepted, more is not.
	okBody := map[string]any{"ciphertext": lcrypto.B64(make([]byte, MaxItemCiphertext)), "nonce": n, "expected_version": 0}
	e.want(e.do("PUT", "/v1/items/"+id, okBody, p.auth()), 201)
	tooBig := map[string]any{"ciphertext": lcrypto.B64(make([]byte, MaxItemCiphertext+1)), "nonce": n, "expected_version": 0}
	e.wantErr(e.do("PUT", "/v1/items/"+lcrypto.NewUUID(), tooBig, p.auth()), 400, "invalid_request")
	huge := map[string]any{"ciphertext": lcrypto.B64(make([]byte, 600<<10)), "nonce": n, "expected_version": 0}
	e.wantErr(e.do("PUT", "/v1/items/"+lcrypto.NewUUID(), huge, p.auth()), 413, "body_too_large")
	if l := e.want(e.do("GET", "/v1/items", nil, p.auth()), 200); len(l.body["items"].([]any)) != 1 {
		t.Fatalf("rejected writes were stored: %d items", len(l.body["items"].([]any)))
	}
}

// ---- setup ----

func TestSetupOnlyOnce(t *testing.T) {
	e := newEnv(t)
	e.wantErr(e.do("GET", "/v1/auth/master/params", nil), 404, "not_initialised")
	p := e.setupVault()

	// A second setup, e.g. by an attacker trying to take over, is refused and changes nothing.
	evil := newPhone(e)
	e.wantErr(e.do("POST", "/v1/setup", e.setupBody(evil)), 409, "already_initialised")
	evil.deviceID = p.deviceID
	if r := evil.tryLogin(); r.status != 401 {
		t.Fatalf("attacker key accepted for the real device: %s", r.raw)
	}
	devs, _ := e.st.ListDevices(context.Background())
	if len(devs) != 1 || !bytes.Equal(devs[0].Ed25519Pub, p.pub) {
		t.Fatalf("devices after refused setup: %+v", devs)
	}
	p.login()
	audit := e.want(e.do("GET", "/v1/audit", nil, p.auth()), 200)
	if !strings.Contains(audit.raw, "already_initialised") {
		t.Fatal("refused setup was not audited")
	}
}

func TestSetupValidation(t *testing.T) {
	e := newEnv(t)
	p := newPhone(e)
	muts := map[string]func(m map[string]any){
		"weak kdf": func(m map[string]any) {
			m["kdf_params"] = lcrypto.KDFParams{Algorithm: "argon2id", Version: 19, MemoryKiB: 8, Time: 1, Parallel: 1, KeyLen: 32, SaltLen: 16}
		},
		"short salt":       func(m map[string]any) { m["salt"] = lcrypto.B64(make([]byte, 8)) },
		"short wrapped":    func(m map[string]any) { m["wrapped_vk_master"] = lcrypto.B64(make([]byte, 48)) },
		"raw vk":           func(m map[string]any) { m["wrapped_vk_recovery"] = lcrypto.B64(p.vk) },
		"bad verifier":     func(m map[string]any) { m["master_auth_verifier"] = "x" },
		"missing verifier": func(m map[string]any) { delete(m, "recovery_auth_verifier") },
		"short totp":       func(m map[string]any) { m["totp_secret"] = lcrypto.B64(make([]byte, 8)) },
		"bad device key": func(m map[string]any) {
			m["device"] = map[string]any{"label": "x", "ed25519_pub": lcrypto.B64(make([]byte, 16))}
		},
		"empty label":   func(m map[string]any) { m["device"] = map[string]any{"label": "  ", "ed25519_pub": lcrypto.B64(p.pub)} },
		"unknown field": func(m map[string]any) { m["vk"] = lcrypto.B64(p.vk) },
	}
	for name, mut := range muts {
		body := e.setupBody(p)
		mut(body)
		if r := e.do("POST", "/v1/setup", body, fromIP("198.51.100."+fmt.Sprint(len(name)))); r.status != 400 {
			t.Errorf("%s: %d %s", name, r.status, r.raw)
		}
	}
	if _, err := e.st.GetVault(context.Background()); err != store.ErrNotFound {
		t.Fatal("an invalid setup created a vault")
	}
}

func TestSetupToken(t *testing.T) {
	e := newEnv(t, func(o *Options) { o.SetupToken = "s3cret-setup-token-xyz" })
	p := newPhone(e)
	e.wantErr(e.do("POST", "/v1/setup", e.setupBody(p)), 403, "setup_token_required")
	e.wantErr(e.do("POST", "/v1/setup", e.setupBody(p), header("X-Leopard-Setup-Token", "wrong")), 403, "setup_token_required")
	e.want(e.do("POST", "/v1/setup", e.setupBody(p), header("X-Leopard-Setup-Token", "s3cret-setup-token-xyz")), 201)
}

func TestTOTPSecretEncryptedAtRest(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	v, _ := e.st.GetVault(context.Background())
	if bytes.Contains(v.TOTPSecretEnc, p.totpSecret) || len(v.TOTPSecretEnc) != 12+len(p.totpSecret)+16 {
		t.Fatal("TOTP secret is not stored encrypted")
	}
	// What the store holds must not include the vault key or the auth keys themselves.
	blob, _ := json.Marshal(v)
	m := master()
	for name, secret := range map[string][]byte{"vk": p.vk, "kek": m.kek, "auth key": m.authKey, "recovery key": p.rk} {
		if bytes.Contains(blob, []byte(lcrypto.B64(secret))) || bytes.Contains(v.WrappedVKMaster, secret) {
			t.Errorf("%s is present in the vault row", name)
		}
	}
}

// ---- device auth ----

func TestDeviceAuthFailures(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	challenge := func(id string) string {
		return e.want(e.do("POST", "/v1/auth/device/challenge", map[string]any{"device_id": id}), 200).str("nonce")
	}
	verify := func(id, nonce string, key ed25519.PrivateKey) resp {
		sig := ed25519.Sign(key, must(lcrypto.DeviceAuthMessage(id, must(lcrypto.UnB64(nonce)))))
		return e.do("POST", "/v1/auth/device/verify", map[string]any{"device_id": id, "nonce": nonce, "signature": lcrypto.B64(sig)})
	}

	// Wrong key.
	_, evil, _ := ed25519.GenerateKey(nil)
	n := challenge(p.deviceID)
	e.wantErr(verify(p.deviceID, n, evil), 401, "device_auth_failed")
	// A failed attempt burns the nonce, even for the right key.
	e.wantErr(verify(p.deviceID, n, p.priv), 401, "device_auth_failed")

	// Replay of a nonce that was used successfully.
	n = challenge(p.deviceID)
	e.want(verify(p.deviceID, n, p.priv), 200)
	e.wantErr(verify(p.deviceID, n, p.priv), 401, "device_auth_failed")

	// A nonce the server never issued.
	e.wantErr(verify(p.deviceID, lcrypto.B64(lcrypto.RandomBytes(32)), p.priv), 401, "device_auth_failed")

	// Expired challenge.
	n = challenge(p.deviceID)
	e.clk.Advance(ChallengeLifetime)
	e.wantErr(verify(p.deviceID, n, p.priv), 401, "device_auth_failed")

	// Unknown device: indistinguishable challenge, verification fails.
	ghost := lcrypto.NewUUID()
	n = challenge(ghost)
	if len(must(lcrypto.UnB64(n))) != 32 {
		t.Fatal("no decoy challenge for an unknown device")
	}
	e.wantErr(verify(ghost, n, p.priv), 401, "device_auth_failed")

	// A signature over a different domain (QR approval bytes) is not a login.
	n = challenge(p.deviceID)
	sig := ed25519.Sign(p.priv, append([]byte(lcrypto.LabelQRApprove), must(lcrypto.UnB64(n))...))
	e.wantErr(e.do("POST", "/v1/auth/device/verify", map[string]any{"device_id": p.deviceID, "nonce": n, "signature": lcrypto.B64(sig)}), 401, "device_auth_failed")

	e.wantErr(e.do("POST", "/v1/auth/device/challenge", map[string]any{"device_id": "nope"}), 400, "invalid_request")
}

// ---- emergency master-password login ----

func TestMasterLogin(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	m := master()

	// Step 1: the browser fetches KDF parameters and re-derives the KEK from the password.
	params := e.want(e.do("GET", "/v1/auth/master/params", nil), 200)
	if _, leaked := params.body["wrapped_vk_master"]; leaked {
		t.Fatal("params endpoint hands out wrapped_vk_master to unauthenticated callers")
	}
	var kp lcrypto.KDFParams
	raw, _ := json.Marshal(params.body["kdf_params"])
	if json.Unmarshal(raw, &kp) != nil || kp != lcrypto.DefaultKDFParams() {
		t.Fatalf("kdf params: %s", params.raw)
	}
	kek := must(lcrypto.DeriveKEK([]byte(testPassword), must(lcrypto.UnB64(params.str("salt"))), kp))
	proof := lcrypto.B64(must(lcrypto.MasterAuthKey(kek)))

	login := func(code, proof string, opts ...reqOpt) resp {
		return e.do("POST", "/v1/auth/master/login", map[string]any{"totp_code": code, "proof": proof}, opts...)
	}
	wrongProof := lcrypto.B64(lcrypto.RandomBytes(32))

	// Either factor alone is not enough, and the answer does not say which was wrong.
	r1 := login(p.totpNow(), wrongProof)
	r2 := login("000000", proof)
	r3 := login("000000", wrongProof)
	for _, r := range []resp{r1, r2, r3} {
		e.wantErr(r, 401, "invalid_credentials")
		if r.raw != r1.raw {
			t.Fatalf("failure responses differ: %q vs %q", r.raw, r1.raw)
		}
	}
	// The KEK itself is not the proof.
	e.wantErr(login(p.totpNow(), lcrypto.B64(m.kek)), 401, "invalid_credentials")

	// Both factors: a web session plus the wrapped vault key, which the password unwraps.
	ok := e.want(login(p.totpNow(), proof, fromIP("203.0.113.5")), 200)
	if ok.str("kind") != "web" || ok.body["idle_timeout_seconds"] != float64(300) {
		t.Fatalf("grant: %s", ok.raw)
	}
	vk, err := lcrypto.UnwrapVK(kek, must(lcrypto.UnB64(ok.str("wrapped_vk_master"))), lcrypto.InfoWrapMaster)
	if err != nil || !bytes.Equal(vk, p.vk) {
		t.Fatalf("master password did not unwrap the vault key: %v", err)
	}
	e.want(e.do("POST", "/v1/sessions/heartbeat", nil, bearer(ok.str("session_token"))), 200)
	e.wantErr(e.do("GET", "/v1/sessions", nil, bearer(ok.str("session_token"))), 403, "mobile_only")

	// The same TOTP code cannot be used twice, even with the right password.
	e.wantErr(login(p.totpNow(), proof, fromIP("203.0.113.6")), 401, "invalid_credentials")
	// The previous step's code is also dead once a later step was accepted.
	prev := totp.CodeAt(p.totpSecret, totp.Step(e.clk.Now())-1)
	e.wantErr(login(prev, proof, fromIP("203.0.113.6")), 401, "invalid_credentials")
	// The next code works.
	e.clk.Advance(30 * time.Second)
	e.want(login(p.totpNow(), proof, fromIP("203.0.113.6")), 200)

	audit := e.want(e.do("GET", "/v1/audit", nil, p.auth()), 200)
	for _, want := range []string{"master_login_ok", "bad_proof", "bad_totp", "totp_replay"} {
		if !strings.Contains(audit.raw, want) {
			t.Errorf("audit log lacks %q", want)
		}
	}
	if strings.Contains(audit.raw, proof) || strings.Contains(e.logs.String(), proof) {
		t.Fatal("the login proof was logged")
	}
}

func TestMasterLoginRateLimits(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	proof := lcrypto.B64(master().authKey)
	bad := func(ip string) resp {
		return e.do("POST", "/v1/auth/master/login", map[string]any{"totp_code": "000000", "proof": lcrypto.B64(lcrypto.RandomBytes(32))}, fromIP(ip))
	}
	// Per IP: five guesses, then 429 even with correct credentials.
	for i := 0; i < 5; i++ {
		e.wantErr(bad("203.0.113.1"), 401, "invalid_credentials")
	}
	r := e.do("POST", "/v1/auth/master/login", map[string]any{"totp_code": p.totpNow(), "proof": proof}, fromIP("203.0.113.1"))
	e.wantErr(r, 429, "rate_limited")
	if r.header.Get("Retry-After") == "" {
		t.Fatal("no Retry-After header")
	}
	// Globally: ten guesses in total, whatever the source address.
	for i := 0; i < 5; i++ {
		e.wantErr(bad(fmt.Sprintf("198.51.100.%d", i+1)), 401, "invalid_credentials")
	}
	e.wantErr(bad("198.51.100.99"), 429, "rate_limited")
	// The limit drains with time.
	e.clk.Advance(15 * time.Minute)
	e.want(e.do("POST", "/v1/auth/master/login", map[string]any{"totp_code": p.totpNow(), "proof": proof}, fromIP("203.0.113.1")), 200)

	for i := 0; i < 5; i++ {
		e.want(e.do("GET", "/v1/auth/master/params", nil, fromIP("203.0.113.77")), 200)
	}
	e.wantErr(e.do("GET", "/v1/auth/master/params", nil, fromIP("203.0.113.77")), 429, "rate_limited")
}

// ---- recovery ----

func TestRecoveryRegistersNewDeviceAndRevokesOld(t *testing.T) {
	e := newEnv(t)
	old := e.setupVault()
	web := e.loggedInBrowser(old)
	pending := e.newBrowser()

	// The user types the recovery key into a new phone.
	display := must(lcrypto.FormatRecoveryKey(old.rk))
	rk := must(lcrypto.ParseRecoveryKey(strings.ToLower(display)))
	np := newPhone(e)
	body := func(proof []byte) map[string]any {
		return map[string]any{"proof": lcrypto.B64(proof), "device": map[string]any{"label": "New phone", "ed25519_pub": lcrypto.B64(np.pub)}}
	}

	e.wantErr(e.do("POST", "/v1/recovery/register-device", body(lcrypto.RandomBytes(32))), 401, "invalid_credentials")
	// Neither the recovery KEK nor the master proof is accepted as the recovery proof.
	e.wantErr(e.do("POST", "/v1/recovery/register-device", body(must(lcrypto.RecoveryKEK(rk)))), 401, "invalid_credentials")
	e.wantErr(e.do("POST", "/v1/recovery/register-device", body(master().authKey)), 401, "invalid_credentials")
	e.want(e.do("GET", "/v1/items", nil, old.auth()), 200) // failures revoked nothing

	r := e.want(e.do("POST", "/v1/recovery/register-device", body(must(lcrypto.RecoveryAuthKey(rk)))), 201)
	np.deviceID = r.str("device_id")
	vk, err := lcrypto.UnwrapVK(must(lcrypto.RecoveryKEK(rk)), must(lcrypto.UnB64(r.str("wrapped_vk_recovery"))), lcrypto.InfoWrapRecovery)
	if err != nil || !bytes.Equal(vk, old.vk) {
		t.Fatalf("recovery key did not unwrap the vault key: %v", err)
	}
	np.vk = vk

	// Everything belonging to the old device is dead.
	e.wantErr(e.do("GET", "/v1/items", nil, old.auth()), 401, "session_revoked")
	e.wantErr(e.do("POST", "/v1/sessions/heartbeat", nil, web.auth()), 401, "session_revoked")
	if lr := old.tryLogin(); lr.status != 401 {
		t.Fatalf("revoked device logged in: %s", lr.raw)
	}
	if pr := pending.poll(); pr.str("status") != "expired" {
		t.Fatalf("pending QR request survived recovery: %s", pr.raw)
	}

	// The new device works end to end.
	np.login()
	b := e.loggedInBrowser(np)
	if !bytes.Equal(b.vk, old.vk) {
		t.Fatal("vault key changed across recovery")
	}
	audit := e.want(e.do("GET", "/v1/audit", nil, np.auth()), 200)
	if !strings.Contains(audit.raw, "recovery_device_registered") || !strings.Contains(audit.raw, "recovery_failed") {
		t.Fatal("recovery events were not audited")
	}
}

func TestRecoveryRateLimit(t *testing.T) {
	e := newEnv(t)
	e.setupVault()
	np := newPhone(e)
	for i := 0; i < 5; i++ {
		r := e.do("POST", "/v1/recovery/register-device", map[string]any{"proof": lcrypto.B64(lcrypto.RandomBytes(32)),
			"device": map[string]any{"label": "x", "ed25519_pub": lcrypto.B64(np.pub)}})
		e.wantErr(r, 401, "invalid_credentials")
	}
	e.wantErr(e.do("POST", "/v1/recovery/register-device", map[string]any{}), 429, "rate_limited")
}

// ---- transport hardening ----

func TestSecurityHeaders(t *testing.T) {
	e := newEnv(t)
	for _, r := range []resp{e.do("GET", "/healthz", nil), e.do("GET", "/v1/items", nil), e.do("GET", "/nope", nil)} {
		want := map[string]string{
			"Strict-Transport-Security": "max-age=63072000; includeSubDomains",
			"X-Content-Type-Options":    "nosniff",
			"X-Frame-Options":           "DENY",
			"Content-Security-Policy":   "default-src 'none'; frame-ancestors 'none'",
			"Referrer-Policy":           "no-referrer",
			"Cache-Control":             "no-store",
		}
		for k, v := range want {
			if r.header.Get(k) != v {
				t.Errorf("%s = %q, want %q", k, r.header.Get(k), v)
			}
		}
		if !strings.HasPrefix(r.header.Get("Content-Type"), "application/json") {
			t.Errorf("content type %q", r.header.Get("Content-Type"))
		}
	}
	if r := e.do("GET", "/healthz", nil); r.status != 200 || r.str("status") != "ok" {
		t.Fatalf("healthz: %s", r.raw)
	}
	e.wantErr(e.do("GET", "/nope", nil), 404, "not_found")
}

func TestCORS(t *testing.T) {
	e := newEnv(t)
	// Allowed origin: preflight and actual request.
	pre := e.do("OPTIONS", "/v1/qr", nil, header("Origin", testOrigin), header("Access-Control-Request-Method", "POST"),
		header("Access-Control-Request-Headers", "content-type"))
	if pre.status != 204 || pre.header.Get("Access-Control-Allow-Origin") != testOrigin ||
		!strings.Contains(pre.header.Get("Access-Control-Allow-Headers"), "X-Leopard-Poll-Token") ||
		!strings.Contains(pre.header.Get("Access-Control-Allow-Methods"), "PUT") {
		t.Fatalf("preflight: %d %v", pre.status, pre.header)
	}
	if pre.header.Get("Access-Control-Allow-Credentials") != "" {
		t.Fatal("credentials must not be allowed")
	}
	ok := e.do("GET", "/healthz", nil, header("Origin", testOrigin))
	if ok.status != 200 || ok.header.Get("Access-Control-Allow-Origin") != testOrigin || ok.header.Get("Vary") != "Origin" {
		t.Fatalf("allowed origin: %d %v", ok.status, ok.header)
	}
	// Any other origin is refused before reaching a handler, and gets no CORS grant.
	for _, o := range []string{"https://evil.example", "https://leopard.example.evil.com", "http://leopard.example", "null"} {
		r := e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32))}, header("Origin", o))
		e.wantErr(r, 403, "origin_not_allowed")
		if r.header.Get("Access-Control-Allow-Origin") != "" {
			t.Fatalf("origin %q was granted CORS", o)
		}
		pf := e.do("OPTIONS", "/v1/qr", nil, header("Origin", o), header("Access-Control-Request-Method", "POST"))
		if pf.status != 403 {
			t.Fatalf("preflight from %q: %d", o, pf.status)
		}
	}
	// Native clients send no Origin and are unaffected.
	e.want(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32))}), 201)
}

func TestBodyHandling(t *testing.T) {
	e := newEnv(t)
	valid := `{"browser_pub":"` + lcrypto.B64(make([]byte, 32)) + `"}`
	e.wantErr(e.do("POST", "/v1/qr", valid, header("Content-Type", "text/plain")), 415, "unsupported_media_type")
	e.wantErr(e.do("POST", "/v1/qr", valid, header("Content-Type", "")), 415, "unsupported_media_type")
	e.wantErr(e.do("POST", "/v1/qr", `{"browser_pub":`), 400, "invalid_json")
	e.wantErr(e.do("POST", "/v1/qr", valid+valid), 400, "invalid_json")
	e.wantErr(e.do("POST", "/v1/qr", `{"browser_pub":"x","extra":1}`), 400, "invalid_json")
	e.wantErr(e.do("POST", "/v1/qr", `{"browser_pub":"`+strings.Repeat("A", 20<<10)+`"}`), 413, "body_too_large")
	e.want(e.do("POST", "/v1/qr", valid, header("Content-Type", "application/json; charset=utf-8")), 201)
}

func TestRateLimitPerIP(t *testing.T) {
	e := newEnv(t)
	body := map[string]any{"browser_pub": lcrypto.B64(make([]byte, 32))}
	for i := 0; i < ruleQRCreate.Burst; i++ {
		e.want(e.do("POST", "/v1/qr", body, fromIP("203.0.113.10")), 201)
	}
	r := e.do("POST", "/v1/qr", body, fromIP("203.0.113.10"))
	e.wantErr(r, 429, "rate_limited")
	if r.header.Get("Retry-After") == "" {
		t.Fatal("no Retry-After")
	}
	// Another address, and another endpoint from the same address, are unaffected.
	e.want(e.do("POST", "/v1/qr", body, fromIP("203.0.113.11")), 201)
	e.want(e.do("GET", "/healthz", nil, fromIP("203.0.113.10")), 200)
	// IPv6 clients are bucketed by /64.
	for i := 0; i < ruleQRCreate.Burst; i++ {
		e.want(e.do("POST", "/v1/qr", body, func(r *http.Request) { r.RemoteAddr = fmt.Sprintf("[2001:db8:1:2::%x]:5000", i+1) }), 201)
	}
	e.wantErr(e.do("POST", "/v1/qr", body, func(r *http.Request) { r.RemoteAddr = "[2001:db8:1:2:ffff::1]:5000" }), 429, "rate_limited")
	e.want(e.do("POST", "/v1/qr", body, func(r *http.Request) { r.RemoteAddr = "[2001:db8:1:3::1]:5000" }), 201)
	e.clk.Advance(time.Minute)
	e.want(e.do("POST", "/v1/qr", body, fromIP("203.0.113.10")), 201)
}

func TestForwardedForTrust(t *testing.T) {
	ipSeen := func(e *env, xff string) string {
		p := e.setupVault()
		b := &browser{e: e, priv: lcrypto.RandomBytes(32)}
		b.pub = must(lcrypto.X25519Public(b.priv))
		opts := []reqOpt{}
		if xff != "" {
			opts = append(opts, header("X-Forwarded-For", xff))
		}
		r := e.want(e.do("POST", "/v1/qr", map[string]any{"browser_pub": lcrypto.B64(b.pub)}, opts...), 201)
		return e.want(e.do("GET", "/v1/qr/"+r.str("sid")+"/details", nil, p.auth()), 200).str("ip")
	}
	// Default: the header is ignored entirely, so it cannot be spoofed.
	if ip := ipSeen(newEnv(t), "6.6.6.6"); ip != "192.0.2.1" {
		t.Fatalf("untrusted XFF used: %s", ip)
	}
	// One trusted hop (Cloud Run): the right-most entry is the real client;
	// anything the client put to its left is ignored.
	one := func(o *Options) { o.TrustedProxyHops = 1 }
	if ip := ipSeen(newEnv(t, one), "6.6.6.6, 203.0.113.50"); ip != "203.0.113.50" {
		t.Fatalf("got %s", ip)
	}
	if ip := ipSeen(newEnv(t, one), "garbage"); ip != "192.0.2.1" {
		t.Fatalf("malformed XFF: got %s", ip)
	}
	if ip := ipSeen(newEnv(t, one), ""); ip != "192.0.2.1" {
		t.Fatalf("missing XFF: got %s", ip)
	}
	two := func(o *Options) { o.TrustedProxyHops = 2 }
	if ip := ipSeen(newEnv(t, two), "6.6.6.6, 203.0.113.50, 10.0.0.1"); ip != "203.0.113.50" {
		t.Fatalf("two hops: got %s", ip)
	}
}

func TestAuditPagination(t *testing.T) {
	e := newEnv(t)
	p := e.setupVault()
	for i := 0; i < 4; i++ {
		e.newBrowser()
	}
	first := e.want(e.do("GET", "/v1/audit?limit=3", nil, p.auth()), 200)
	entries := first.body["entries"].([]any)
	if len(entries) != 3 || first.body["next_before"] == nil {
		t.Fatalf("page 1: %s", first.raw)
	}
	next := int64(first.body["next_before"].(float64))
	second := e.want(e.do("GET", fmt.Sprintf("/v1/audit?limit=100&before=%d", next), nil, p.auth()), 200)
	if len(second.body["entries"].([]any)) != 3 || second.body["next_before"] != nil {
		t.Fatalf("page 2: %s", second.raw)
	}
	e.wantErr(e.do("GET", "/v1/audit?limit=0", nil, p.auth()), 400, "invalid_request")
	e.wantErr(e.do("GET", "/v1/audit?before=x", nil, p.auth()), 400, "invalid_request")
}

func TestHealthzReportsDatabaseFailure(t *testing.T) {
	e := newEnvWithStore(t, failingPing{store.NewMem()})
	if r := e.do("GET", "/healthz", nil); r.status != 503 || strings.Contains(r.raw, "boom") {
		t.Fatalf("healthz: %d %s", r.status, r.raw)
	}
}

type failingPing struct{ store.Store }

func (failingPing) Ping(context.Context) error { return fmt.Errorf("boom: secret dsn") }

func TestNewRejectsBadOptions(t *testing.T) {
	if _, err := New(Options{ServerKey: make([]byte, 32)}); err == nil {
		t.Fatal("nil store accepted")
	}
	if _, err := New(Options{Store: store.NewMem(), ServerKey: make([]byte, 31)}); err == nil {
		t.Fatal("short server key accepted")
	}
}
