// Package ratelimit is a small in-memory token-bucket rate limiter keyed by
// an arbitrary string (the API uses "<rule>|<client ip>").
//
// State lives in process memory, which is correct for a single instance. Run
// the service with max-instances=1, or accept that limits are per instance.
package ratelimit

import (
	"math"
	"sync"
	"time"
)

// Rule describes a bucket: it holds at most Burst tokens and refills at
// Burst tokens per Per.
type Rule struct {
	Name  string
	Burst int
	Per   time.Duration
}

func (r Rule) ratePerSec() float64 { return float64(r.Burst) / r.Per.Seconds() }

type bucket struct {
	tokens float64
	last   time.Time
	rule   Rule
}

// Limiter holds the buckets. The zero value is not usable; call New.
type Limiter struct {
	mu      sync.Mutex
	buckets map[string]*bucket
	now     func() time.Time
	maxKeys int
}

// DefaultMaxKeys bounds memory use under an address-spraying attack.
const DefaultMaxKeys = 50000

// New returns a limiter. now may be nil (time.Now).
func New(now func() time.Time) *Limiter {
	if now == nil {
		now = time.Now
	}
	return &Limiter{buckets: map[string]*bucket{}, now: now, maxKeys: DefaultMaxKeys}
}

// SetMaxKeys overrides the bucket cap (for tests).
func (l *Limiter) SetMaxKeys(n int) {
	l.mu.Lock()
	l.maxKeys = n
	l.mu.Unlock()
}

// Allow takes one token from the bucket for (rule, key). When the bucket is
// empty it returns false and how long until a token is available.
func (l *Limiter) Allow(rule Rule, key string) (ok bool, retryAfter time.Duration) {
	if rule.Burst <= 0 || rule.Per <= 0 {
		return false, time.Hour
	}
	now := l.now()
	k := rule.Name + "|" + key
	l.mu.Lock()
	defer l.mu.Unlock()
	b, found := l.buckets[k]
	if !found {
		if len(l.buckets) >= l.maxKeys {
			l.sweepLocked(now)
			if len(l.buckets) >= l.maxKeys {
				// Fail closed: under this much key churn, refuse new clients
				// rather than let the limiter be bypassed or memory grow.
				return false, time.Second
			}
		}
		b = &bucket{tokens: float64(rule.Burst), last: now, rule: rule}
		l.buckets[k] = b
	} else {
		if dt := now.Sub(b.last).Seconds(); dt > 0 {
			b.tokens = math.Min(float64(rule.Burst), b.tokens+dt*rule.ratePerSec())
			b.last = now
		}
	}
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	wait := (1 - b.tokens) / rule.ratePerSec()
	return false, time.Duration(math.Ceil(wait*1000)) * time.Millisecond
}

// Sweep drops buckets that have refilled completely; they carry no state.
func (l *Limiter) Sweep() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sweepLocked(l.now())
}

func (l *Limiter) sweepLocked(now time.Time) int {
	n := 0
	for k, b := range l.buckets {
		if b.tokens+now.Sub(b.last).Seconds()*b.rule.ratePerSec() >= float64(b.rule.Burst) {
			delete(l.buckets, k)
			n++
		}
	}
	return n
}

// Len returns the number of live buckets.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
