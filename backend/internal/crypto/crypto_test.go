package crypto

import (
	"bytes"
	"crypto/ed25519"
	"encoding/hex"
	"strings"
	"testing"
)

func TestItemRoundTripAndBinding(t *testing.T) {
	vk := RandomBytes(KeySize)
	key := must(DeriveItemKey(vk))
	id, other := NewUUID(), NewUUID()
	nonce := RandomBytes(NonceSize)
	pt := []byte(`{"type":"note","title":"t"}`)
	ct := must(SealItem(key, nonce, id, 3, pt))
	if len(ct) != len(pt)+TagSize {
		t.Fatalf("ciphertext length %d", len(ct))
	}
	got, err := OpenItem(key, nonce, id, 3, ct)
	if err != nil || !bytes.Equal(got, pt) {
		t.Fatalf("round trip: %v", err)
	}
	if _, err := OpenItem(key, nonce, other, 3, ct); err != ErrDecrypt {
		t.Errorf("ciphertext accepted under another item id: %v", err)
	}
	if _, err := OpenItem(key, nonce, id, 4, ct); err != ErrDecrypt {
		t.Errorf("ciphertext accepted under another version: %v", err)
	}
	otherKey := must(DeriveItemKey(RandomBytes(KeySize)))
	if _, err := OpenItem(otherKey, nonce, id, 3, ct); err != ErrDecrypt {
		t.Errorf("ciphertext accepted under another key: %v", err)
	}
	for i := range ct {
		bad := bytes.Clone(ct)
		bad[i] ^= 1
		if _, err := OpenItem(key, nonce, id, 3, bad); err != ErrDecrypt {
			t.Fatalf("bit flip at %d accepted", i)
		}
	}
	if _, err := SealItem(key, nonce, strings.ToUpper(id), 1, pt); err == nil {
		t.Error("upper-case item id accepted")
	}
	if _, err := SealItem(key, nonce[:11], id, 1, pt); err != ErrSize {
		t.Error("short nonce accepted")
	}
}

func TestItemKeyDiffersFromVK(t *testing.T) {
	vk := RandomBytes(KeySize)
	if bytes.Equal(must(DeriveItemKey(vk)), vk) {
		t.Fatal("item key equals VK")
	}
	if _, err := DeriveItemKey(vk[:31]); err != ErrSize {
		t.Fatal("short VK accepted")
	}
}

// RFC 5869 A.1 checks that hkdf32 is plain HKDF-SHA256 (first 32 of 42 bytes).
func TestHKDFRFC5869(t *testing.T) {
	ikm := bytes.Repeat([]byte{0x0b}, 22)
	salt := must(hex.DecodeString("000102030405060708090a0b0c"))
	info := string(must(hex.DecodeString("f0f1f2f3f4f5f6f7f8f9")))
	want := "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf"
	if got := hx(hkdf32(ikm, salt, info)); got != want {
		t.Fatalf("got %s", got)
	}
}

// RFC 7748 section 6.1.
func TestX25519RFC7748(t *testing.T) {
	aPriv := must(hex.DecodeString("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
	bPriv := must(hex.DecodeString("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
	if got := hx(must(X25519Public(aPriv))); got != "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a" {
		t.Fatalf("alice pub %s", got)
	}
	bPub := must(X25519Public(bPriv))
	if got := hx(must(X25519Shared(aPriv, bPub))); got != "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742" {
		t.Fatalf("shared %s", got)
	}
}

func TestX25519RejectsLowOrderPoint(t *testing.T) {
	if _, err := X25519Shared(RandomBytes(32), make([]byte, 32)); err == nil {
		t.Fatal("all-zero peer key accepted")
	}
}

func TestWrapUnwrap(t *testing.T) {
	vk, kek, nonce := RandomBytes(32), RandomBytes(32), RandomBytes(12)
	w := must(WrapVK(kek, nonce, vk, InfoWrapMaster))
	if len(w) != WrappedVKSize {
		t.Fatalf("wrapped size %d", len(w))
	}
	if got, err := UnwrapVK(kek, w, InfoWrapMaster); err != nil || !bytes.Equal(got, vk) {
		t.Fatalf("unwrap: %v", err)
	}
	if _, err := UnwrapVK(kek, w, InfoWrapRecovery); err != ErrDecrypt {
		t.Error("master blob accepted as recovery blob")
	}
	if _, err := UnwrapVK(RandomBytes(32), w, InfoWrapMaster); err != ErrDecrypt {
		t.Error("wrong KEK accepted")
	}
	if _, err := UnwrapVK(kek, w[:59], InfoWrapMaster); err != ErrSize {
		t.Error("truncated blob accepted")
	}
}

func TestKDFParamsValidate(t *testing.T) {
	if err := DefaultKDFParams().Validate(); err != nil {
		t.Fatal(err)
	}
	mut := []func(*KDFParams){
		func(p *KDFParams) { p.Algorithm = "argon2i" },
		func(p *KDFParams) { p.Version = 16 },
		func(p *KDFParams) { p.MemoryKiB = 1024 },
		func(p *KDFParams) { p.MemoryKiB = 1 << 22 },
		func(p *KDFParams) { p.Time = 1 },
		func(p *KDFParams) { p.Parallel = 0 },
		func(p *KDFParams) { p.KeyLen = 16 },
		func(p *KDFParams) { p.SaltLen = 8 },
	}
	for i, m := range mut {
		p := DefaultKDFParams()
		m(&p)
		if p.Validate() == nil {
			t.Errorf("mutation %d accepted", i)
		}
		if _, err := DeriveKEK([]byte("pw"), make([]byte, 16), p); err == nil {
			t.Errorf("DeriveKEK ran with invalid params (mutation %d)", i)
		}
	}
}

func TestMasterAuthKey(t *testing.T) {
	kek := RandomBytes(32)
	ak := must(MasterAuthKey(kek))
	if bytes.Equal(ak, kek) {
		t.Fatal("auth key equals KEK")
	}
	v := AuthVerifier(ak)
	if !CheckAuthKey(ak, v) {
		t.Fatal("correct auth key rejected")
	}
	if CheckAuthKey(RandomBytes(32), v) || CheckAuthKey(ak[:31], v) || CheckAuthKey(nil, v) {
		t.Fatal("wrong auth key accepted")
	}
}

func TestRecoveryKeyFormat(t *testing.T) {
	rk := RandomBytes(RecoveryKeySize)
	s := must(FormatRecoveryKey(rk))
	if len(s) != 32 || strings.Count(s, "-") != 6 || len(s[strings.LastIndex(s, "-")+1:]) != 2 {
		t.Fatalf("unexpected shape %q", s)
	}
	for _, variant := range []string{s, strings.ToLower(s), strings.ReplaceAll(s, "-", ""), " " + strings.ReplaceAll(s, "-", " ") + "\n"} {
		got, err := ParseRecoveryKey(variant)
		if err != nil || !bytes.Equal(got, rk) {
			t.Errorf("parse %q: %v", variant, err)
		}
	}
	for _, bad := range []string{"", s[:len(s)-1], s + "A", strings.Replace(s, s[:1], "1", 1), strings.Replace(s, s[:1], "!", 1)} {
		if _, err := ParseRecoveryKey(bad); err == nil {
			t.Errorf("accepted %q", bad)
		}
	}
	// 26 base32 chars carry 130 bits; the last two must be zero.
	clean := strings.ReplaceAll(s, "-", "")
	if _, err := ParseRecoveryKey(clean[:25] + "B"); err == nil && clean[25:] != "B" {
		t.Error("non-canonical trailing bits accepted")
	}
	if _, err := FormatRecoveryKey(rk[:15]); err != ErrSize {
		t.Error("short recovery key accepted")
	}
	if bytes.Equal(must(RecoveryKEK(rk)), must(RecoveryAuthKey(rk))) {
		t.Error("recovery KEK equals recovery auth key")
	}
}

func TestQRTransferEndToEnd(t *testing.T) {
	vk := RandomBytes(32)
	browserPriv, phonePriv := RandomBytes(32), RandomBytes(32)
	browserPub, phonePub := must(X25519Public(browserPriv)), must(X25519Public(phonePriv))
	sid, nonce := RandomBytes(SIDSize), RandomBytes(NonceSize)

	ct := must(QRSealVK(phonePriv, browserPub, sid, nonce, vk))
	got, err := QROpenVK(browserPriv, phonePub, sid, nonce, ct)
	if err != nil || !bytes.Equal(got, vk) {
		t.Fatalf("browser could not recover VK: %v", err)
	}
	// A different session id, a different browser or a tampered phone key must all fail.
	if _, err := QROpenVK(browserPriv, phonePub, RandomBytes(SIDSize), nonce, ct); err != ErrDecrypt {
		t.Error("accepted under another sid")
	}
	if _, err := QROpenVK(RandomBytes(32), phonePub, sid, nonce, ct); err != ErrDecrypt {
		t.Error("another browser key decrypted the payload")
	}
	if _, err := QROpenVK(browserPriv, must(X25519Public(RandomBytes(32))), sid, nonce, ct); err != ErrDecrypt {
		t.Error("accepted with a substituted phone key")
	}

	pub, priv, _ := ed25519.GenerateKey(nil)
	msg := must(QRApproveMessage(sid, browserPub, phonePub, nonce, ct))
	if want := len(LabelQRApprove) + 16 + 32 + 32 + 12 + 48; len(msg) != want {
		t.Fatalf("approve message length %d want %d", len(msg), want)
	}
	sig := ed25519.Sign(priv, msg)
	if !Ed25519Verify(pub, msg, sig) {
		t.Fatal("signature rejected")
	}
	other := must(QRApproveMessage(RandomBytes(SIDSize), browserPub, phonePub, nonce, ct))
	if Ed25519Verify(pub, other, sig) {
		t.Fatal("signature accepted for another sid")
	}
	if Ed25519Verify(pub[:31], msg, sig) || Ed25519Verify(pub, msg, sig[:63]) {
		t.Fatal("malformed key or signature accepted")
	}
	if _, err := QRApproveMessage(sid, browserPub, phonePub, nonce, ct[:47]); err != ErrSize {
		t.Fatal("short ciphertext accepted in approve message")
	}
}

func TestVerifyCode(t *testing.T) {
	sid, pub := RandomBytes(SIDSize), RandomBytes(32)
	c := must(VerifyCode(sid, pub))
	if len(c) != 6 || strings.Trim(c, "0123456789") != "" {
		t.Fatalf("bad code %q", c)
	}
	if c != must(VerifyCode(sid, pub)) {
		t.Fatal("not deterministic")
	}
	if _, err := VerifyCode(sid[:15], pub); err != ErrSize {
		t.Fatal("short sid accepted")
	}
}

func TestBase64URL(t *testing.T) {
	b := []byte{0xfb, 0xff, 0xfe}
	if B64(b) != "-__-" {
		t.Fatalf("got %q", B64(b))
	}
	for _, bad := range []string{"+//+", "-__-=", "-__", "-_ _-", "AB"} {
		if got, err := UnB64(bad); err == nil && bad != "-__" {
			t.Errorf("accepted %q -> %x", bad, got)
		}
	}
	// "AB" has non-zero trailing bits and must be rejected by the strict decoder.
	if _, err := UnB64("AB"); err == nil {
		t.Error("non-canonical trailing bits accepted")
	}
}

func TestUUID(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		u := NewUUID()
		if !IsCanonicalUUID(u) || u[14] != '4' || seen[u] {
			t.Fatalf("bad uuid %q", u)
		}
		seen[u] = true
	}
	for _, bad := range []string{"", "0F8FAD5B-D9CB-469F-A165-70867728950E", "0f8fad5bd9cb469fa16570867728950e", "0f8fad5b-d9cb-469f-a165-70867728950g", "0f8fad5b-d9cb-469f-a165-70867728950e0"} {
		if IsCanonicalUUID(bad) {
			t.Errorf("accepted %q", bad)
		}
	}
}

func TestDeviceAuthMessage(t *testing.T) {
	id := NewUUID()
	m := must(DeviceAuthMessage(id, RandomBytes(32)))
	if len(m) != len(LabelDeviceAuth)+36+32 {
		t.Fatalf("length %d", len(m))
	}
	if _, err := DeviceAuthMessage(id, RandomBytes(31)); err == nil {
		t.Fatal("short challenge accepted")
	}
	if _, err := DeviceAuthMessage("nope", RandomBytes(32)); err == nil {
		t.Fatal("bad device id accepted")
	}
}
