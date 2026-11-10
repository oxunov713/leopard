package auth

import (
	"bytes"
	"net/http"
	"testing"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
)

func TestTokens(t *testing.T) {
	tok, hash := NewToken()
	if len(tok) != 43 || len(hash) != 32 {
		t.Fatalf("token %q hash %d", tok, len(hash))
	}
	h2, ok := HashToken(tok)
	if !ok || !bytes.Equal(h2, hash) {
		t.Fatal("hash mismatch")
	}
	tok2, hash2 := NewToken()
	if tok2 == tok || bytes.Equal(hash2, hash) {
		t.Fatal("tokens repeat")
	}
	for _, bad := range []string{"", "short", tok + "A", tok[:42] + "=", tok[:42] + "+"} {
		if _, ok := HashToken(bad); ok {
			t.Errorf("accepted %q", bad)
		}
	}
	if bytes.Contains(hash, []byte(tok)) {
		t.Fatal("hash contains token")
	}
}

func TestBearer(t *testing.T) {
	r, _ := http.NewRequest("GET", "/", nil)
	if _, ok := BearerToken(r); ok {
		t.Fatal("no header accepted")
	}
	for h, want := range map[string]string{"Bearer abc": "abc", "bearer abc": "abc", "Basic abc": "", "Bearer": "", "Bearer ": ""} {
		r.Header.Set("Authorization", h)
		got, ok := BearerToken(r)
		if got != want || ok != (want != "") {
			t.Errorf("%q -> %q %v", h, got, ok)
		}
	}
}

func TestSecretBox(t *testing.T) {
	if _, err := NewSecretBox(make([]byte, 16)); err == nil {
		t.Fatal("short key accepted")
	}
	b, _ := NewSecretBox(lcrypto.RandomBytes(32))
	secret := []byte("totp-secret-0123456789")
	sealed, err := b.Seal(secret, LabelTOTP)
	if err != nil || bytes.Contains(sealed, secret) {
		t.Fatalf("seal: %v", err)
	}
	if got, err := b.Open(sealed, LabelTOTP); err != nil || !bytes.Equal(got, secret) {
		t.Fatalf("open: %v", err)
	}
	if _, err := b.Open(sealed, "other"); err == nil {
		t.Fatal("opened under another label")
	}
	other, _ := NewSecretBox(lcrypto.RandomBytes(32))
	if _, err := other.Open(sealed, LabelTOTP); err == nil {
		t.Fatal("opened with another key")
	}
	if _, err := b.Open(sealed[:10], LabelTOTP); err == nil {
		t.Fatal("opened truncated box")
	}
	s2, _ := b.Seal(secret, LabelTOTP)
	if bytes.Equal(s2, sealed) {
		t.Fatal("nonce reuse")
	}
	if !EqualString("a", "a") || EqualString("a", "b") || EqualString("a", "aa") {
		t.Fatal("EqualString")
	}
}
