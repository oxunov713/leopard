// Package crypto is the Go reference implementation of the Leopard
// cryptographic protocol described in docs/crypto-spec.md.
//
// Everything that takes a nonce, salt or key takes it as an explicit argument
// so that the functions are deterministic and can be checked against
// docs/test-vectors.json. Callers are responsible for supplying fresh random
// values (see RandomBytes).
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/argon2"
)

// Sizes, in bytes.
const (
	KeySize         = 32 // VK, KEK, item key, auth keys, QR transfer key
	NonceSize       = 12 // AES-GCM nonce
	TagSize         = 16 // AES-GCM tag
	SaltSize        = 16 // Argon2id salt
	RecoveryKeySize = 16
	SIDSize         = 16 // QR session id
	X25519KeySize   = 32
	// WrappedVKSize is nonce || ciphertext || tag for a 32-byte VK.
	WrappedVKSize = NonceSize + KeySize + TagSize
	// QRCiphertextSize is ciphertext || tag for a 32-byte VK.
	QRCiphertextSize = KeySize + TagSize
	// DeviceChallengeSize is the size of a device-auth challenge nonce.
	DeviceChallengeSize = 32
)

// Domain-separation labels. All are ASCII without a terminating NUL.
const (
	InfoItem         = "leopard/item/v1"
	InfoWrapMaster   = "leopard/wrap/master/v1"
	InfoWrapRecovery = "leopard/wrap/recovery/v1"
	InfoAuthMaster   = "leopard/auth/v1"
	InfoAuthRecovery = "leopard/auth/recovery/v1"
	InfoQR           = "leopard/qr/v1"
	LabelQRApprove   = "leopard/qr-approve/v1"
	LabelVerify      = "leopard/verify/v1"
	LabelDeviceAuth  = "leopard/device-auth/v1"
)

// KDFParams are the Argon2id parameters. They are stored with the vault so
// they can be raised later without breaking old clients.
type KDFParams struct {
	Algorithm string `json:"alg"`      // always "argon2id"
	Version   int    `json:"v"`        // Argon2 version, always 19 (0x13)
	MemoryKiB uint32 `json:"m_kib"`    // memory cost in KiB
	Time      uint32 `json:"t"`        // iterations
	Parallel  uint8  `json:"p"`        // lanes
	KeyLen    uint32 `json:"dk_len"`   // output length in bytes
	SaltLen   uint32 `json:"salt_len"` // salt length in bytes
}

// DefaultKDFParams are the v1 parameters: m=64 MiB, t=3, p=1.
func DefaultKDFParams() KDFParams {
	return KDFParams{Algorithm: "argon2id", Version: 19, MemoryKiB: 65536, Time: 3, Parallel: 1, KeyLen: KeySize, SaltLen: SaltSize}
}

// Validate rejects parameters this implementation will not run. The lower
// bounds stop a malicious server from downgrading the KDF; the upper bounds
// stop it from exhausting client memory.
func (p KDFParams) Validate() error {
	switch {
	case p.Algorithm != "argon2id":
		return errors.New("crypto: kdf algorithm must be argon2id")
	case p.Version != 19:
		return errors.New("crypto: argon2 version must be 19")
	case p.MemoryKiB < 65536 || p.MemoryKiB > 1<<20:
		return errors.New("crypto: argon2 memory out of range")
	case p.Time < 3 || p.Time > 16:
		return errors.New("crypto: argon2 time out of range")
	case p.Parallel < 1 || p.Parallel > 4:
		return errors.New("crypto: argon2 parallelism out of range")
	case p.KeyLen != KeySize:
		return errors.New("crypto: argon2 output must be 32 bytes")
	case p.SaltLen != SaltSize:
		return errors.New("crypto: argon2 salt must be 16 bytes")
	}
	return nil
}

var (
	// ErrDecrypt is returned for every authenticated-decryption failure.
	ErrDecrypt = errors.New("crypto: decryption failed")
	// ErrSize is returned when an input has the wrong length.
	ErrSize = errors.New("crypto: invalid input size")
)

var b64 = base64.RawURLEncoding.Strict()

// B64 encodes binary for the wire: base64url, no padding.
func B64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// UnB64 decodes strict base64url without padding.
func UnB64(s string) ([]byte, error) { return b64.DecodeString(s) }

// RandomBytes returns n bytes from the OS CSPRNG.
func RandomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic("crypto: system RNG failed: " + err.Error())
	}
	return b
}

// hkdf32 is HKDF-SHA256 (extract-then-expand, RFC 5869) with a 32-byte output.
func hkdf32(ikm, salt []byte, info string) []byte {
	out, err := hkdf.Key(sha256.New, ikm, salt, info, KeySize)
	if err != nil {
		panic("crypto: hkdf: " + err.Error())
	}
	return out
}

func gcm(key []byte) (cipher.AEAD, error) {
	if len(key) != KeySize {
		return nil, ErrSize
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Seal is AES-256-GCM. It returns ciphertext || tag (the nonce is not included).
func Seal(key, nonce, plaintext, aad []byte) ([]byte, error) {
	a, err := gcm(key)
	if err != nil {
		return nil, err
	}
	if len(nonce) != NonceSize {
		return nil, ErrSize
	}
	return a.Seal(nil, nonce, plaintext, aad), nil
}

// Open reverses Seal.
func Open(key, nonce, ciphertext, aad []byte) ([]byte, error) {
	a, err := gcm(key)
	if err != nil {
		return nil, err
	}
	if len(nonce) != NonceSize || len(ciphertext) < TagSize {
		return nil, ErrSize
	}
	pt, err := a.Open(nil, nonce, ciphertext, aad)
	if err != nil {
		return nil, ErrDecrypt
	}
	return pt, nil
}

// ---- Items ----

// DeriveItemKey returns HKDF-SHA256(VK, salt=empty, info="leopard/item/v1").
func DeriveItemKey(vk []byte) ([]byte, error) {
	if len(vk) != KeySize {
		return nil, ErrSize
	}
	return hkdf32(vk, nil, InfoItem), nil
}

// ItemAAD is item_id (the 36 ASCII bytes of the canonical lower-case UUID)
// followed by version as a big-endian uint64.
func ItemAAD(itemID string, version uint64) ([]byte, error) {
	if !IsCanonicalUUID(itemID) {
		return nil, fmt.Errorf("crypto: item id %q is not a canonical lower-case UUID", itemID)
	}
	aad := make([]byte, 0, 36+8)
	aad = append(aad, itemID...)
	return binary.BigEndian.AppendUint64(aad, version), nil
}

// SealItem encrypts an item's JSON plaintext.
func SealItem(itemKey, nonce []byte, itemID string, version uint64, plaintext []byte) ([]byte, error) {
	aad, err := ItemAAD(itemID, version)
	if err != nil {
		return nil, err
	}
	return Seal(itemKey, nonce, plaintext, aad)
}

// OpenItem decrypts an item. It fails if the ciphertext was produced for a
// different item id or version.
func OpenItem(itemKey, nonce []byte, itemID string, version uint64, ciphertext []byte) ([]byte, error) {
	aad, err := ItemAAD(itemID, version)
	if err != nil {
		return nil, err
	}
	return Open(itemKey, nonce, ciphertext, aad)
}

// IsCanonicalUUID reports whether s is 8-4-4-4-12 lower-case hex.
func IsCanonicalUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i := 0; i < 36; i++ {
		c := s[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
				return false
			}
		}
	}
	return true
}

// NewUUID returns a random (version 4) UUID in canonical form.
func NewUUID() string {
	b := RandomBytes(16)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// ---- Master password ----

// DeriveKEK runs Argon2id over the UTF-8 bytes of the master password.
func DeriveKEK(password, salt []byte, p KDFParams) ([]byte, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if len(salt) != int(p.SaltLen) {
		return nil, ErrSize
	}
	return argon2.IDKey(password, salt, p.Time, p.MemoryKiB, p.Parallel, p.KeyLen), nil
}

// WrapVK returns nonce || AES-256-GCM(kek, nonce, vk, aad=label) (60 bytes).
// label is InfoWrapMaster or InfoWrapRecovery.
func WrapVK(kek, nonce, vk []byte, label string) ([]byte, error) {
	if len(vk) != KeySize {
		return nil, ErrSize
	}
	ct, err := Seal(kek, nonce, vk, []byte(label))
	if err != nil {
		return nil, err
	}
	return append(append(make([]byte, 0, WrappedVKSize), nonce...), ct...), nil
}

// UnwrapVK reverses WrapVK.
func UnwrapVK(kek, wrapped []byte, label string) ([]byte, error) {
	if len(wrapped) != WrappedVKSize {
		return nil, ErrSize
	}
	return Open(kek, wrapped[:NonceSize], wrapped[NonceSize:], []byte(label))
}

// MasterAuthKey returns HKDF-SHA256(KEK, salt=empty, info="leopard/auth/v1").
// The client sends it as the login proof; the server stores only AuthVerifier.
func MasterAuthKey(kek []byte) ([]byte, error) {
	if len(kek) != KeySize {
		return nil, ErrSize
	}
	return hkdf32(kek, nil, InfoAuthMaster), nil
}

// AuthVerifier is SHA-256(auth_key), the value the server stores.
func AuthVerifier(authKey []byte) []byte {
	h := sha256.Sum256(authKey)
	return h[:]
}

// CheckAuthKey compares SHA-256(authKey) to verifier in constant time.
func CheckAuthKey(authKey, verifier []byte) bool {
	if len(authKey) != KeySize {
		return false
	}
	return subtle.ConstantTimeCompare(AuthVerifier(authKey), verifier) == 1
}

// ---- Recovery key ----

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// FormatRecoveryKey renders 16 bytes as 26 Base32 characters in groups of
// four separated by dashes: XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX.
func FormatRecoveryKey(rk []byte) (string, error) {
	if len(rk) != RecoveryKeySize {
		return "", ErrSize
	}
	s := b32.EncodeToString(rk)
	var sb strings.Builder
	for i := 0; i < len(s); i += 4 {
		if i > 0 {
			sb.WriteByte('-')
		}
		sb.WriteString(s[i:min(i+4, len(s))])
	}
	return sb.String(), nil
}

// ParseRecoveryKey accepts the displayed form. Dashes and ASCII whitespace
// are ignored and letters are upper-cased; the result must re-encode to the
// same 26 characters (so non-zero trailing bits are rejected).
func ParseRecoveryKey(s string) ([]byte, error) {
	var sb strings.Builder
	for _, r := range s {
		switch {
		case r == '-' || r == ' ' || r == '\t' || r == '\n' || r == '\r':
		case r >= 'a' && r <= 'z':
			sb.WriteRune(r - 'a' + 'A')
		default:
			sb.WriteRune(r)
		}
	}
	clean := sb.String()
	if len(clean) != 26 {
		return nil, errors.New("crypto: recovery key must be 26 base32 characters")
	}
	rk, err := b32.DecodeString(clean)
	if err != nil || len(rk) != RecoveryKeySize || b32.EncodeToString(rk) != clean {
		return nil, errors.New("crypto: malformed recovery key")
	}
	return rk, nil
}

// RecoveryKEK returns HKDF-SHA256(rk, salt=empty, info="leopard/wrap/recovery/v1").
func RecoveryKEK(rk []byte) ([]byte, error) {
	if len(rk) != RecoveryKeySize {
		return nil, ErrSize
	}
	return hkdf32(rk, nil, InfoWrapRecovery), nil
}

// RecoveryAuthKey returns HKDF-SHA256(rk, salt=empty, info="leopard/auth/recovery/v1").
func RecoveryAuthKey(rk []byte) ([]byte, error) {
	if len(rk) != RecoveryKeySize {
		return nil, ErrSize
	}
	return hkdf32(rk, nil, InfoAuthRecovery), nil
}

// ---- QR key transfer ----

// X25519Public returns the public key for a 32-byte X25519 private key.
func X25519Public(priv []byte) ([]byte, error) {
	k, err := ecdh.X25519().NewPrivateKey(priv)
	if err != nil {
		return nil, ErrSize
	}
	return k.PublicKey().Bytes(), nil
}

// X25519Shared computes the raw X25519 shared secret (RFC 7748). It fails if
// the result is all zero (low-order peer point).
func X25519Shared(priv, peerPub []byte) ([]byte, error) {
	k, err := ecdh.X25519().NewPrivateKey(priv)
	if err != nil {
		return nil, ErrSize
	}
	p, err := ecdh.X25519().NewPublicKey(peerPub)
	if err != nil {
		return nil, ErrSize
	}
	return k.ECDH(p)
}

// QRTransferKey returns HKDF-SHA256(shared, salt=sid,
// info="leopard/qr/v1" || browser_pub || phone_pub).
func QRTransferKey(shared, sid, browserPub, phonePub []byte) ([]byte, error) {
	if len(shared) != 32 || len(sid) != SIDSize || len(browserPub) != X25519KeySize || len(phonePub) != X25519KeySize {
		return nil, ErrSize
	}
	info := InfoQR + string(browserPub) + string(phonePub)
	return hkdf32(shared, sid, info), nil
}

// QRSealVK is the phone side: it encrypts VK for the browser and returns
// ciphertext || tag (48 bytes). AAD is sid.
func QRSealVK(phoneEphPriv, browserPub, sid, nonce, vk []byte) ([]byte, error) {
	if len(vk) != KeySize {
		return nil, ErrSize
	}
	phonePub, err := X25519Public(phoneEphPriv)
	if err != nil {
		return nil, err
	}
	shared, err := X25519Shared(phoneEphPriv, browserPub)
	if err != nil {
		return nil, err
	}
	key, err := QRTransferKey(shared, sid, browserPub, phonePub)
	if err != nil {
		return nil, err
	}
	return Seal(key, nonce, vk, sid)
}

// QROpenVK is the browser side.
func QROpenVK(browserPriv, phoneEphPub, sid, nonce, ciphertext []byte) ([]byte, error) {
	if len(ciphertext) != QRCiphertextSize {
		return nil, ErrSize
	}
	browserPub, err := X25519Public(browserPriv)
	if err != nil {
		return nil, err
	}
	shared, err := X25519Shared(browserPriv, phoneEphPub)
	if err != nil {
		return nil, err
	}
	key, err := QRTransferKey(shared, sid, browserPub, phoneEphPub)
	if err != nil {
		return nil, err
	}
	return Open(key, nonce, ciphertext, sid)
}

// QRApproveMessage is the canonical byte string the phone signs:
// "leopard/qr-approve/v1" || sid || browser_pub || phone_eph_pub || nonce || ciphertext.
// Every component has a fixed length, so the concatenation is unambiguous.
func QRApproveMessage(sid, browserPub, phoneEphPub, nonce, ciphertext []byte) ([]byte, error) {
	if len(sid) != SIDSize || len(browserPub) != X25519KeySize || len(phoneEphPub) != X25519KeySize ||
		len(nonce) != NonceSize || len(ciphertext) != QRCiphertextSize {
		return nil, ErrSize
	}
	m := make([]byte, 0, len(LabelQRApprove)+SIDSize+2*X25519KeySize+NonceSize+QRCiphertextSize)
	m = append(m, LabelQRApprove...)
	m = append(m, sid...)
	m = append(m, browserPub...)
	m = append(m, phoneEphPub...)
	m = append(m, nonce...)
	m = append(m, ciphertext...)
	return m, nil
}

// VerifyCode is the 6-digit code shown on both screens: the first three bytes
// of SHA-256("leopard/verify/v1" || sid || browser_pub) as a big-endian
// uint24, modulo 1 000 000, zero-padded.
func VerifyCode(sid, browserPub []byte) (string, error) {
	if len(sid) != SIDSize || len(browserPub) != X25519KeySize {
		return "", ErrSize
	}
	h := sha256.New()
	h.Write([]byte(LabelVerify))
	h.Write(sid)
	h.Write(browserPub)
	d := h.Sum(nil)
	n := uint32(d[0])<<16 | uint32(d[1])<<8 | uint32(d[2])
	return fmt.Sprintf("%06d", n%1000000), nil
}

// ---- Device authentication ----

// DeviceAuthMessage is what a device signs to log in:
// "leopard/device-auth/v1" || device_id (36 ASCII bytes) || challenge (32 bytes).
func DeviceAuthMessage(deviceID string, challenge []byte) ([]byte, error) {
	if !IsCanonicalUUID(deviceID) || len(challenge) != DeviceChallengeSize {
		return nil, ErrSize
	}
	m := make([]byte, 0, len(LabelDeviceAuth)+36+DeviceChallengeSize)
	m = append(m, LabelDeviceAuth...)
	m = append(m, deviceID...)
	m = append(m, challenge...)
	return m, nil
}

// Ed25519Verify checks an RFC 8032 Ed25519 signature, validating lengths first.
func Ed25519Verify(pub, msg, sig []byte) bool {
	if len(pub) != ed25519.PublicKeySize || len(sig) != ed25519.SignatureSize {
		return false
	}
	return ed25519.Verify(ed25519.PublicKey(pub), msg, sig)
}

// SHA256 is a convenience wrapper returning a slice.
func SHA256(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

// QRURI is the text encoded in the QR code shown by the browser:
// leopard://qr?v=1&sid=<base64url sid>&pk=<base64url browser_pub>.
func QRURI(sid, browserPub []byte) string {
	return "leopard://qr?v=1&sid=" + B64(sid) + "&pk=" + B64(browserPub)
}
