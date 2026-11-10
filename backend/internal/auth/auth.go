// Package auth holds the server-side credential helpers: opaque bearer
// tokens (stored only as SHA-256 hashes) and the secret box that encrypts the
// TOTP secret with the server key.
package auth

import (
	"crypto/subtle"
	"errors"
	"net/http"
	"strings"

	lcrypto "github.com/leopard-vault/leopard/backend/internal/crypto"
)

// TokenSize is the number of random bytes in a session or poll token.
const TokenSize = 32

// tokenChars is the length of a base64url-encoded token.
const tokenChars = 43

// NewToken returns a fresh token and the hash to store.
func NewToken() (token string, hash []byte) {
	raw := lcrypto.RandomBytes(TokenSize)
	return lcrypto.B64(raw), lcrypto.SHA256(raw)
}

// HashToken validates the token's shape and returns SHA-256 of its raw bytes.
func HashToken(token string) ([]byte, bool) {
	if len(token) != tokenChars {
		return nil, false
	}
	raw, err := lcrypto.UnB64(token)
	if err != nil || len(raw) != TokenSize {
		return nil, false
	}
	return lcrypto.SHA256(raw), true
}

// BearerToken extracts the token from "Authorization: Bearer <token>".
func BearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const p = "Bearer "
	if len(h) <= len(p) || !strings.EqualFold(h[:len(p)], p) {
		return "", false
	}
	return strings.TrimSpace(h[len(p):]), true
}

// Equal is a constant-time comparison of two byte strings.
func Equal(a, b []byte) bool { return subtle.ConstantTimeCompare(a, b) == 1 }

// EqualString compares two strings in constant time with respect to their
// contents by comparing their SHA-256 digests.
func EqualString(a, b string) bool {
	return Equal(lcrypto.SHA256([]byte(a)), lcrypto.SHA256([]byte(b)))
}

// SecretBox encrypts small server-side secrets with LEOPARD_SERVER_KEY using
// AES-256-GCM. The stored form is nonce(12) || ciphertext || tag.
type SecretBox struct {
	key []byte
}

// LabelTOTP is the AAD for the encrypted TOTP secret.
const LabelTOTP = "leopard/server/totp/v1"

// NewSecretBox requires a 32-byte key.
func NewSecretBox(key []byte) (*SecretBox, error) {
	if len(key) != lcrypto.KeySize {
		return nil, errors.New("auth: server key must be 32 bytes")
	}
	return &SecretBox{key: append([]byte(nil), key...)}, nil
}

// Seal encrypts plaintext under a fresh random nonce.
func (b *SecretBox) Seal(plaintext []byte, label string) ([]byte, error) {
	nonce := lcrypto.RandomBytes(lcrypto.NonceSize)
	ct, err := lcrypto.Seal(b.key, nonce, plaintext, []byte(label))
	if err != nil {
		return nil, err
	}
	return append(nonce, ct...), nil
}

// Open reverses Seal.
func (b *SecretBox) Open(sealed []byte, label string) ([]byte, error) {
	if len(sealed) < lcrypto.NonceSize+lcrypto.TagSize {
		return nil, lcrypto.ErrSize
	}
	return lcrypto.Open(b.key, sealed[:lcrypto.NonceSize], sealed[lcrypto.NonceSize:], []byte(label))
}
