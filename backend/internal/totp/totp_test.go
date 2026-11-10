package totp

import (
	"testing"
	"time"
)

// RFC 6238 Appendix B, SHA-1 rows, truncated to six digits.
var rfcSecret = []byte("12345678901234567890")

func TestRFC6238Vectors(t *testing.T) {
	cases := []struct {
		unix int64
		code string
	}{
		{59, "287082"},
		{1111111109, "081804"},
		{1111111111, "050471"},
		{1234567890, "005924"},
		{2000000000, "279037"},
		{20000000000, "353130"},
	}
	for _, c := range cases {
		if got := Code(rfcSecret, time.Unix(c.unix, 0)); got != c.code {
			t.Errorf("t=%d: got %s want %s", c.unix, got, c.code)
		}
	}
}

func TestRFC4226Vectors(t *testing.T) {
	want := []string{"755224", "287082", "359152", "969429", "338314", "254676", "287922", "162583", "399871", "520489"}
	for i, w := range want {
		if got := CodeAt(rfcSecret, uint64(i)); got != w {
			t.Errorf("counter %d: got %s want %s", i, got, w)
		}
	}
}

func TestVerifyWindow(t *testing.T) {
	now := time.Unix(1700000000, 0)
	cur := Step(now)
	for d := -2; d <= 2; d++ {
		code := CodeAt(rfcSecret, cur+uint64(d))
		step, ok := Verify(rfcSecret, code, now)
		wantOK := d >= -Skew && d <= Skew
		if ok != wantOK {
			t.Errorf("delta %d: ok=%v want %v", d, ok, wantOK)
		}
		if ok && step != cur+uint64(d) {
			t.Errorf("delta %d: step=%d want %d", d, step, cur+uint64(d))
		}
	}
}

func TestVerifyRejectsMalformed(t *testing.T) {
	now := time.Unix(1700000000, 0)
	for _, code := range []string{"", "12345", "1234567", "12a456", " 23456", "１２３４５６"} {
		if _, ok := Verify(rfcSecret, code, now); ok {
			t.Errorf("accepted malformed code %q", code)
		}
	}
	good := Code(rfcSecret, now)
	if _, ok := Verify([]byte("another-secret-0123456789"), good, now); ok {
		t.Error("accepted code for a different secret")
	}
}

func TestStepBoundaries(t *testing.T) {
	if Step(time.Unix(29, 0)) != 0 || Step(time.Unix(30, 0)) != 1 || Step(time.Unix(-5, 0)) != 0 {
		t.Error("step boundaries wrong")
	}
	// At the very start of time the window must not underflow.
	if _, ok := Verify(rfcSecret, CodeAt(rfcSecret, 0), time.Unix(0, 0)); !ok {
		t.Error("code at step 0 rejected")
	}
}
