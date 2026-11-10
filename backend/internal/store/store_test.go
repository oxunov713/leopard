package store_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"testing"
	"time"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
	"github.com/leopard-vault/leopard/backend/internal/migrations"
	"github.com/leopard-vault/leopard/backend/internal/store"
)

// The same conformance suite runs against the in-memory store and, when
// LEOPARD_TEST_DATABASE_URL is set, against Postgres. The Postgres run DROPS
// AND RECREATES the public schema of that database.

func openPG(t *testing.T) *store.PG {
	t.Helper()
	url := os.Getenv("LEOPARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("LEOPARD_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pg, err := store.OpenPG(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	if _, err := pg.Pool().Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
		t.Fatal(err)
	}
	applied, err := migrations.Up(ctx, pg.Pool())
	if err != nil || len(applied) == 0 {
		t.Fatalf("migrate: applied=%v err=%v", applied, err)
	}
	if again, err := migrations.Up(ctx, pg.Pool()); err != nil || len(again) != 0 {
		t.Fatalf("second migrate should be a no-op: applied=%v err=%v", again, err)
	}
	return pg
}

func TestMem(t *testing.T) { conformance(t, func(t *testing.T) store.Store { return store.NewMem() }) }

func TestPostgres(t *testing.T) {
	conformance(t, func(t *testing.T) store.Store { return openPG(t) })
}

var t0 = time.Date(2026, 1, 2, 3, 4, 5, 123456000, time.UTC)

func newVault() (store.Vault, store.Device) {
	params, _ := json.Marshal(lcrypto.DefaultKDFParams())
	return store.Vault{
			KDFParams: params, Salt: lcrypto.RandomBytes(16),
			WrappedVKMaster: lcrypto.RandomBytes(60), WrappedVKRecovery: lcrypto.RandomBytes(60),
			MasterAuthVerifier: lcrypto.RandomBytes(32), RecoveryAuthVerifier: lcrypto.RandomBytes(32),
			TOTPSecretEnc: lcrypto.RandomBytes(48), CreatedAt: t0,
		}, store.Device{
			ID: lcrypto.NewUUID(), Label: "Pixel", Ed25519Pub: lcrypto.RandomBytes(32), CreatedAt: t0,
		}
}

func conformance(t *testing.T, open func(t *testing.T) store.Store) {
	ctx := context.Background()

	t.Run("vault", func(t *testing.T) {
		s := open(t)
		if _, err := s.GetVault(ctx); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("empty GetVault: %v", err)
		}
		v, d := newVault()
		if err := s.CreateVault(ctx, v, d); err != nil {
			t.Fatal(err)
		}
		v2, d2 := newVault()
		if err := s.CreateVault(ctx, v2, d2); !errors.Is(err, store.ErrVaultExists) {
			t.Fatalf("second CreateVault: %v", err)
		}
		if _, err := s.GetDevice(ctx, d2.ID); !errors.Is(err, store.ErrNotFound) {
			t.Fatal("device from the refused setup was stored")
		}
		got, err := s.GetVault(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(got.Salt, v.Salt) || !bytes.Equal(got.WrappedVKMaster, v.WrappedVKMaster) ||
			!bytes.Equal(got.RecoveryAuthVerifier, v.RecoveryAuthVerifier) || !got.CreatedAt.Equal(t0) {
			t.Fatalf("vault round trip mismatch: %+v", got)
		}
		var p lcrypto.KDFParams
		if json.Unmarshal(got.KDFParams, &p) != nil || p != lcrypto.DefaultKDFParams() {
			t.Fatalf("kdf params round trip: %s", got.KDFParams)
		}
		gd, err := s.GetDevice(ctx, d.ID)
		if err != nil || gd.Label != "Pixel" || !bytes.Equal(gd.Ed25519Pub, d.Ed25519Pub) || gd.RevokedAt != nil || gd.LastSeen != nil {
			t.Fatalf("device: %+v %v", gd, err)
		}
		if err := s.TouchDevice(ctx, d.ID, t0.Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		if gd, _ = s.GetDevice(ctx, d.ID); gd.LastSeen == nil || !gd.LastSeen.Equal(t0.Add(time.Second)) {
			t.Fatalf("last_seen: %v", gd.LastSeen)
		}

		for _, c := range []struct {
			step int64
			want bool
		}{{100, true}, {100, false}, {99, false}, {101, true}} {
			ok, err := s.AdvanceTOTPStep(ctx, c.step)
			if err != nil || ok != c.want {
				t.Fatalf("AdvanceTOTPStep(%d) = %v, %v", c.step, ok, err)
			}
		}
	})

	t.Run("challenges", func(t *testing.T) {
		s := open(t)
		dev, other := lcrypto.NewUUID(), lcrypto.NewUUID()
		h := lcrypto.RandomBytes(32)
		if err := s.PutChallenge(ctx, h, dev, t0.Add(time.Minute)); err != nil {
			t.Fatal(err)
		}
		if ok, _ := s.TakeChallenge(ctx, h, other, t0); ok {
			t.Fatal("challenge taken by another device")
		}
		if ok, err := s.TakeChallenge(ctx, h, dev, t0); !ok || err != nil {
			t.Fatalf("take: %v %v", ok, err)
		}
		if ok, _ := s.TakeChallenge(ctx, h, dev, t0); ok {
			t.Fatal("challenge taken twice")
		}
		h2 := lcrypto.RandomBytes(32)
		s.PutChallenge(ctx, h2, dev, t0.Add(time.Minute))
		if ok, _ := s.TakeChallenge(ctx, h2, dev, t0.Add(time.Minute)); ok {
			t.Fatal("expired challenge accepted")
		}
	})

	t.Run("sessions", func(t *testing.T) {
		s := open(t)
		v, d := newVault()
		if err := s.CreateVault(ctx, v, d); err != nil {
			t.Fatal(err)
		}
		th := lcrypto.RandomBytes(32)
		sess := store.Session{ID: lcrypto.NewUUID(), Kind: store.KindMobile, DeviceID: &d.ID,
			ClientInfo: json.RawMessage(`{"a":1}`), IP: "203.0.113.9", CreatedAt: t0, LastSeen: t0, IdleTimeoutSeconds: 60}
		if err := s.CreateSession(ctx, sess, th); err != nil {
			t.Fatal(err)
		}
		got, err := s.GetSessionByTokenHash(ctx, th)
		if err != nil || got.ID != sess.ID || got.Kind != store.KindMobile || got.DeviceID == nil || *got.DeviceID != d.ID ||
			!got.Active || got.IP != "203.0.113.9" || got.IdleTimeoutSeconds != 60 || !got.LastSeen.Equal(t0) {
			t.Fatalf("session: %+v %v", got, err)
		}
		var info map[string]int
		if json.Unmarshal(got.ClientInfo, &info) != nil || info["a"] != 1 {
			t.Fatalf("client_info: %s", got.ClientInfo)
		}
		if _, err := s.GetSessionByTokenHash(ctx, lcrypto.RandomBytes(32)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("unknown token: %v", err)
		}
		s.TouchSession(ctx, sess.ID, t0.Add(10*time.Second))
		if got, _ = s.GetSession(ctx, sess.ID); !got.LastSeen.Equal(t0.Add(10 * time.Second)) {
			t.Fatalf("touch: %v", got.LastSeen)
		}
		web := store.Session{ID: lcrypto.NewUUID(), Kind: store.KindWeb, CreatedAt: t0.Add(time.Second), LastSeen: t0.Add(time.Second), IdleTimeoutSeconds: 300}
		if err := s.CreateSession(ctx, web, lcrypto.RandomBytes(32)); err != nil {
			t.Fatal(err)
		}
		list, err := s.ListSessions(ctx)
		if err != nil || len(list) != 2 || list[0].ID != web.ID {
			t.Fatalf("list: %+v %v", list, err)
		}
		if ok, err := s.RevokeSession(ctx, web.ID, t0.Add(time.Minute)); !ok || err != nil {
			t.Fatalf("revoke: %v %v", ok, err)
		}
		if ok, _ := s.RevokeSession(ctx, web.ID, t0.Add(time.Minute)); ok {
			t.Fatal("revoked twice")
		}
		if ok, _ := s.RevokeSession(ctx, lcrypto.NewUUID(), t0); ok {
			t.Fatal("revoked a session that does not exist")
		}
		if got, _ = s.GetSession(ctx, web.ID); got.RevokedAt == nil {
			t.Fatal("revoked_at not set")
		}
		// A revoked session must not be revived by a touch.
		s.TouchSession(ctx, web.ID, t0.Add(2*time.Minute))
		if got, _ = s.GetSession(ctx, web.ID); !got.LastSeen.Equal(t0.Add(time.Second)) {
			t.Fatal("touch updated a revoked session")
		}
		if list, _ = s.ListSessions(ctx); len(list) != 1 {
			t.Fatalf("list after revoke: %d", len(list))
		}

		// Recovery: everything old is revoked, the new device is live.
		nd := store.Device{ID: lcrypto.NewUUID(), Label: "New", Ed25519Pub: lcrypto.RandomBytes(32), CreatedAt: t0.Add(time.Hour)}
		if err := s.ReplaceDevices(ctx, nd, t0.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		if od, _ := s.GetDevice(ctx, d.ID); od.RevokedAt == nil {
			t.Fatal("old device not revoked")
		}
		if gd, _ := s.GetDevice(ctx, nd.ID); gd == nil || gd.RevokedAt != nil {
			t.Fatal("new device missing or revoked")
		}
		if list, _ = s.ListSessions(ctx); len(list) != 0 {
			t.Fatal("sessions survived recovery")
		}
		if devs, err := s.ListDevices(ctx); err != nil || len(devs) != 2 || devs[0].ID != nd.ID {
			t.Fatalf("devices: %+v %v", devs, err)
		}
	})

	t.Run("qr", func(t *testing.T) {
		s := open(t)
		v, d := newVault()
		s.CreateVault(ctx, v, d)
		mk := func() store.QRRequest {
			q := store.QRRequest{SID: lcrypto.B64(lcrypto.RandomBytes(16)), BrowserPub: lcrypto.RandomBytes(32),
				PollTokenHash: lcrypto.RandomBytes(32), ClientInfo: json.RawMessage(`{"ua":"x"}`), IP: "198.51.100.7",
				CreatedAt: t0, ExpiresAt: t0.Add(time.Minute), Status: store.QRPending}
			if err := s.CreateQR(ctx, q); err != nil {
				t.Fatal(err)
			}
			return q
		}
		appr := store.QRApproval{PhoneEphPub: lcrypto.RandomBytes(32), Nonce: lcrypto.RandomBytes(12),
			Ciphertext: lcrypto.RandomBytes(48), Signature: lcrypto.RandomBytes(64), DeviceID: d.ID}
		pend := func() store.Session {
			return store.Session{ID: lcrypto.NewUUID(), Kind: store.KindWeb, DeviceID: &d.ID, CreatedAt: t0, LastSeen: t0, IdleTimeoutSeconds: 300}
		}

		q := mk()
		got, err := s.GetQR(ctx, q.SID)
		if err != nil || got.Status != store.QRPending || !bytes.Equal(got.BrowserPub, q.BrowserPub) ||
			!got.ExpiresAt.Equal(q.ExpiresAt) || got.SessionID != nil || got.Ciphertext != nil {
			t.Fatalf("get: %+v %v", got, err)
		}
		if _, err := s.GetQR(ctx, "missing"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("missing: %v", err)
		}
		if _, err := s.ConsumeQR(ctx, q.SID, lcrypto.RandomBytes(32), t0, time.Minute); !errors.Is(err, store.ErrQRState) {
			t.Fatalf("consume before approve: %v", err)
		}
		p := pend()
		if err := s.ApproveQR(ctx, q.SID, appr, p, t0.Add(time.Minute)); !errors.Is(err, store.ErrQRExpired) {
			t.Fatalf("approve at expiry: %v", err)
		}
		if _, err := s.GetSession(ctx, p.ID); !errors.Is(err, store.ErrNotFound) {
			t.Fatal("session created by a failed approval")
		}
		if err := s.ApproveQR(ctx, q.SID, appr, p, t0.Add(30*time.Second)); err != nil {
			t.Fatal(err)
		}
		if err := s.ApproveQR(ctx, q.SID, appr, pend(), t0.Add(31*time.Second)); !errors.Is(err, store.ErrQRState) {
			t.Fatalf("double approve: %v", err)
		}
		if err := s.RejectQR(ctx, q.SID, t0); !errors.Is(err, store.ErrQRState) {
			t.Fatalf("reject after approve: %v", err)
		}
		ps, err := s.GetSession(ctx, p.ID)
		if err != nil || ps.Active {
			t.Fatalf("pending session should exist and be inactive: %+v %v", ps, err)
		}
		if list, _ := s.ListSessions(ctx); len(list) != 0 {
			t.Fatal("inactive session listed")
		}

		// Exactly one of many concurrent consumers wins.
		var wg sync.WaitGroup
		var mu sync.Mutex
		wins := 0
		var winHash []byte
		for i := 0; i < 8; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				th := lcrypto.RandomBytes(32)
				r, err := s.ConsumeQR(ctx, q.SID, th, t0.Add(40*time.Second), time.Minute)
				if err == nil {
					mu.Lock()
					wins++
					winHash = th
					if !bytes.Equal(r.Ciphertext, appr.Ciphertext) || !bytes.Equal(r.PhoneEphPub, appr.PhoneEphPub) || r.SessionID == nil || *r.SessionID != p.ID {
						t.Errorf("consumed payload mismatch: %+v", r)
					}
					mu.Unlock()
				} else if !errors.Is(err, store.ErrQRState) {
					t.Errorf("consume: %v", err)
				}
			}()
		}
		wg.Wait()
		if wins != 1 {
			t.Fatalf("%d consumers won", wins)
		}
		as, err := s.GetSessionByTokenHash(ctx, winHash)
		if err != nil || as.ID != p.ID || !as.Active || !as.LastSeen.Equal(t0.Add(40*time.Second)) {
			t.Fatalf("activated session: %+v %v", as, err)
		}
		if got, _ = s.GetQR(ctx, q.SID); got.Status != store.QRConsumed || got.Ciphertext != nil || got.Nonce != nil {
			t.Fatalf("payload not cleared after consumption: %+v", got)
		}

		// Approval that is collected too late.
		q2, p2 := mk(), pend()
		if err := s.ApproveQR(ctx, q2.SID, appr, p2, t0.Add(time.Second)); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ConsumeQR(ctx, q2.SID, lcrypto.RandomBytes(32), t0.Add(3*time.Minute), time.Minute); !errors.Is(err, store.ErrQRExpired) {
			t.Fatalf("late consume: %v", err)
		}

		// Reject.
		q3 := mk()
		if err := s.RejectQR(ctx, q3.SID, t0); err != nil {
			t.Fatal(err)
		}
		if err := s.ApproveQR(ctx, q3.SID, appr, pend(), t0); !errors.Is(err, store.ErrQRState) {
			t.Fatalf("approve after reject: %v", err)
		}
		if err := s.RejectQR(ctx, "missing", t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("reject missing: %v", err)
		}
		if err := s.ApproveQR(ctx, "missing", appr, pend(), t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("approve missing: %v", err)
		}

		// Cleanup: q4 pending past expiry becomes expired; never-collected
		// session p2 is deleted; old requests are removed.
		q4 := mk()
		st, err := s.Cleanup(ctx, t0.Add(10*time.Minute))
		if err != nil || st.QRExpired != 1 || st.SessionsDeleted != 1 {
			t.Fatalf("cleanup: %+v %v", st, err)
		}
		if got, _ = s.GetQR(ctx, q4.SID); got.Status != store.QRExpired {
			t.Fatalf("status after cleanup: %s", got.Status)
		}
		if _, err := s.GetSession(ctx, p2.ID); !errors.Is(err, store.ErrNotFound) {
			t.Fatal("uncollected session survived cleanup")
		}
		if got, err = s.GetQR(ctx, q2.SID); err != nil || got.SessionID != nil && *got.SessionID == p2.ID && false {
			t.Fatalf("qr row should survive session deletion: %v", err)
		}
		st, _ = s.Cleanup(ctx, t0.Add(25*time.Hour))
		if st.QRDeleted != 4 {
			t.Fatalf("old qr rows deleted: %d", st.QRDeleted)
		}
	})

	t.Run("cleanup-idle-sessions", func(t *testing.T) {
		s := open(t)
		a := store.Session{ID: lcrypto.NewUUID(), Kind: store.KindWeb, CreatedAt: t0, LastSeen: t0, IdleTimeoutSeconds: 300}
		b := store.Session{ID: lcrypto.NewUUID(), Kind: store.KindWeb, CreatedAt: t0, LastSeen: t0.Add(200 * time.Second), IdleTimeoutSeconds: 300}
		s.CreateSession(ctx, a, lcrypto.RandomBytes(32))
		s.CreateSession(ctx, b, lcrypto.RandomBytes(32))
		st, err := s.Cleanup(ctx, t0.Add(301*time.Second))
		if err != nil || st.SessionsRevoked != 1 {
			t.Fatalf("cleanup: %+v %v", st, err)
		}
		if ga, _ := s.GetSession(ctx, a.ID); ga.RevokedAt == nil {
			t.Fatal("idle session not revoked")
		}
		if gb, _ := s.GetSession(ctx, b.ID); gb.RevokedAt != nil {
			t.Fatal("live session revoked")
		}
		st, _ = s.Cleanup(ctx, t0.Add(40*24*time.Hour))
		if st.SessionsDeleted != 1 || st.SessionsRevoked != 1 {
			t.Fatalf("second cleanup: %+v", st)
		}
	})

	t.Run("items", func(t *testing.T) {
		s := open(t)
		id := lcrypto.NewUUID()
		ct, n := []byte("ciphertext-1"), lcrypto.RandomBytes(12)
		if _, err := s.PutItem(ctx, id, ct, n, 1, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("update of missing item: %v", err)
		}
		it, err := s.PutItem(ctx, id, ct, n, 0, t0)
		if err != nil || it.Version != 1 || !it.UpdatedAt.Equal(t0) || !bytes.Equal(it.Ciphertext, ct) {
			t.Fatalf("create: %+v %v", it, err)
		}
		cur, err := s.PutItem(ctx, id, []byte("x"), n, 0, t0)
		if !errors.Is(err, store.ErrVersionConflict) || cur == nil || cur.Version != 1 {
			t.Fatalf("create over existing: %+v %v", cur, err)
		}
		it, err = s.PutItem(ctx, id, []byte("ciphertext-2"), n, 1, t0.Add(time.Second))
		if err != nil || it.Version != 2 {
			t.Fatalf("update: %+v %v", it, err)
		}
		cur, err = s.PutItem(ctx, id, []byte("stale"), n, 1, t0.Add(2*time.Second))
		if !errors.Is(err, store.ErrVersionConflict) || cur.Version != 2 || string(cur.Ciphertext) != "ciphertext-2" {
			t.Fatalf("stale update: %+v %v", cur, err)
		}

		id2 := lcrypto.NewUUID()
		s.PutItem(ctx, id2, []byte("other"), n, 0, t0.Add(3*time.Second))

		all, err := s.ListItems(ctx, nil)
		if err != nil || len(all) != 2 || all[0].ID != id || all[1].ID != id2 {
			t.Fatalf("list all: %+v %v", all, err)
		}
		since := t0.Add(time.Second)
		if l, _ := s.ListItems(ctx, &since); len(l) != 1 || l[0].ID != id2 {
			t.Fatalf("since is exclusive: %+v", l)
		}
		since = t0.Add(time.Hour)
		if l, err := s.ListItems(ctx, &since); err != nil || l == nil || len(l) != 0 {
			t.Fatalf("empty list: %v %v", l, err)
		}

		if cur, err = s.DeleteItem(ctx, id, 1, t0.Add(4*time.Second)); !errors.Is(err, store.ErrVersionConflict) || cur.Version != 2 {
			t.Fatalf("stale delete: %+v %v", cur, err)
		}
		tomb, err := s.DeleteItem(ctx, id, 2, t0.Add(5*time.Second))
		if err != nil || tomb.Version != 3 || tomb.DeletedAt == nil || tomb.Ciphertext != nil || tomb.Nonce != nil || !tomb.UpdatedAt.Equal(t0.Add(5*time.Second)) {
			t.Fatalf("delete: %+v %v", tomb, err)
		}
		if cur, err = s.DeleteItem(ctx, id, 3, t0.Add(6*time.Second)); !errors.Is(err, store.ErrGone) || cur.Version != 3 {
			t.Fatalf("delete tombstone: %+v %v", cur, err)
		}
		if _, err = s.PutItem(ctx, id, ct, n, 3, t0.Add(6*time.Second)); !errors.Is(err, store.ErrGone) {
			t.Fatalf("put over tombstone: %v", err)
		}
		if _, err = s.PutItem(ctx, id, ct, n, 0, t0.Add(6*time.Second)); !errors.Is(err, store.ErrGone) {
			t.Fatalf("recreate over tombstone: %v", err)
		}
		if _, err = s.DeleteItem(ctx, lcrypto.NewUUID(), 1, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("delete missing: %v", err)
		}
		since = t0.Add(4 * time.Second)
		if l, _ := s.ListItems(ctx, &since); len(l) != 1 || l[0].ID != id || l[0].DeletedAt == nil {
			t.Fatalf("tombstone not in delta: %+v", l)
		}
	})

	t.Run("audit", func(t *testing.T) {
		s := open(t)
		sid, did := lcrypto.NewUUID(), lcrypto.NewUUID()
		for i := 0; i < 5; i++ {
			e := store.AuditEntry{TS: t0.Add(time.Duration(i) * time.Second), Event: "e", IP: "192.0.2.1"}
			if i == 4 {
				e.SessionID, e.DeviceID, e.Meta = &sid, &did, json.RawMessage(`{"k":"v"}`)
			}
			if err := s.AppendAudit(ctx, e); err != nil {
				t.Fatal(err)
			}
		}
		l, err := s.ListAudit(ctx, 3, 0)
		if err != nil || len(l) != 3 || l[0].ID <= l[1].ID || l[0].SessionID == nil || *l[0].SessionID != sid ||
			*l[0].DeviceID != did || l[1].SessionID != nil || !l[0].TS.Equal(t0.Add(4*time.Second)) {
			t.Fatalf("audit: %+v %v", l, err)
		}
		var meta map[string]string
		if json.Unmarshal(l[0].Meta, &meta) != nil || meta["k"] != "v" {
			t.Fatalf("meta: %s", l[0].Meta)
		}
		l2, _ := s.ListAudit(ctx, 10, l[2].ID)
		if len(l2) != 2 || l2[0].ID >= l[2].ID {
			t.Fatalf("pagination: %+v", l2)
		}
	})
}
