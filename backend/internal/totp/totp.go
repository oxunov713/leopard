// Package totp implements RFC 6238 TOTP with HMAC-SHA1, a 30 second step and
// six digits, which is what every authenticator app supports.
package totp

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/binary"
	"fmt"
	"time"
)

const (
	// Period is the time step in seconds.
	Period = 30
	// Digits is the code length.
	Digits = 6
	// Skew is how many steps either side of the current one are accepted.
	Skew = 1
	// MinSecretSize is the smallest accepted secret (RFC 4226 requires 128
	// bits and recommends 160).
	MinSecretSize = 16
	// MaxSecretSize bounds the secret so it fits comfortably in a QR code.
	MaxSecretSize = 64
)

// Step returns the RFC 6238 time-step counter for t.
func Step(t time.Time) uint64 {
	u := t.Unix()
	if u < 0 {
		return 0
	}
	return uint64(u) / Period
}

// CodeAt returns the six-digit code for a given counter (RFC 4226 HOTP).
func CodeAt(secret []byte, counter uint64) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], counter)
	mac := hmac.New(sha1.New, secret)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	bin := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", bin%1000000)
}

// Code returns the code valid at time t.
func Code(secret []byte, t time.Time) string { return CodeAt(secret, Step(t)) }

// Verify checks code against the steps now-Skew..now+Skew. It returns the
// matching step so the caller can refuse to accept the same step twice. The
// comparison of each candidate is constant-time and every candidate is always
// evaluated.
func Verify(secret []byte, code string, now time.Time) (step uint64, ok bool) {
	if len(code) != Digits {
		return 0, false
	}
	for i := 0; i < Digits; i++ {
		if code[i] < '0' || code[i] > '9' {
			return 0, false
		}
	}
	cur := Step(now)
	for d := -Skew; d <= Skew; d++ {
		if d < 0 && cur < uint64(-d) {
			continue
		}
		s := cur + uint64(d)
		if subtle.ConstantTimeCompare([]byte(CodeAt(secret, s)), []byte(code)) == 1 && !ok {
			step, ok = s, true
		}
	}
	return step, ok
}
