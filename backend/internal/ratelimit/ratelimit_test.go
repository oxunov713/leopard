package ratelimit

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

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

func TestBurstThenRefill(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	l := New(clk.Now)
	r := Rule{Name: "login", Burst: 5, Per: time.Minute}
	for i := 0; i < 5; i++ {
		if ok, _ := l.Allow(r, "1.2.3.4"); !ok {
			t.Fatalf("request %d denied inside burst", i)
		}
	}
	ok, retry := l.Allow(r, "1.2.3.4")
	if ok {
		t.Fatal("6th request allowed")
	}
	if retry <= 11*time.Second || retry > 12*time.Second {
		t.Fatalf("retry-after %v, want ~12s (one token per 12s)", retry)
	}
	clk.Advance(11 * time.Second)
	if ok, _ := l.Allow(r, "1.2.3.4"); ok {
		t.Fatal("allowed before a token was refilled")
	}
	clk.Advance(1 * time.Second)
	if ok, _ := l.Allow(r, "1.2.3.4"); !ok {
		t.Fatal("denied after refill")
	}
	if ok, _ := l.Allow(r, "1.2.3.4"); ok {
		t.Fatal("only one token should have been refilled")
	}
	// A long quiet period refills to the burst, not beyond it.
	clk.Advance(time.Hour)
	n := 0
	for i := 0; i < 20; i++ {
		if ok, _ := l.Allow(r, "1.2.3.4"); ok {
			n++
		}
	}
	if n != 5 {
		t.Fatalf("after idle got %d, want burst of 5", n)
	}
}

func TestKeysAndRulesAreIndependent(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	l := New(clk.Now)
	a := Rule{Name: "a", Burst: 1, Per: time.Minute}
	b := Rule{Name: "b", Burst: 1, Per: time.Minute}
	if ok, _ := l.Allow(a, "ip1"); !ok {
		t.Fatal()
	}
	if ok, _ := l.Allow(a, "ip1"); ok {
		t.Fatal("same key, same rule allowed twice")
	}
	if ok, _ := l.Allow(a, "ip2"); !ok {
		t.Fatal("another key was affected")
	}
	if ok, _ := l.Allow(b, "ip1"); !ok {
		t.Fatal("another rule was affected")
	}
}

func TestSweepAndCap(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	l := New(clk.Now)
	l.SetMaxKeys(3)
	r := Rule{Name: "r", Burst: 2, Per: 10 * time.Second}
	for i := 0; i < 3; i++ {
		if ok, _ := l.Allow(r, fmt.Sprint(i)); !ok {
			t.Fatal("denied below cap")
		}
	}
	if ok, _ := l.Allow(r, "new"); ok {
		t.Fatal("new key admitted beyond the cap (must fail closed)")
	}
	if ok, _ := l.Allow(r, "0"); !ok {
		t.Fatal("existing key denied at cap")
	}
	clk.Advance(time.Minute)
	if ok, _ := l.Allow(r, "new"); !ok {
		t.Fatal("cap not relieved after buckets refilled")
	}
	if l.Len() != 1 {
		t.Fatalf("len %d after sweep, want 1", l.Len())
	}
	clk.Advance(time.Minute)
	if n := l.Sweep(); n != 1 || l.Len() != 0 {
		t.Fatalf("sweep removed %d, len %d", n, l.Len())
	}
}

func TestInvalidRuleDenies(t *testing.T) {
	l := New(nil)
	if ok, _ := l.Allow(Rule{Name: "zero"}, "k"); ok {
		t.Fatal("zero rule allowed a request")
	}
}

func TestConcurrentNeverExceedsBurst(t *testing.T) {
	clk := &fakeClock{t: time.Unix(1000, 0)}
	l := New(clk.Now)
	r := Rule{Name: "c", Burst: 50, Per: time.Hour}
	var wg sync.WaitGroup
	var mu sync.Mutex
	allowed := 0
	for i := 0; i < 500; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if ok, _ := l.Allow(r, "k"); ok {
				mu.Lock()
				allowed++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if allowed != 50 {
		t.Fatalf("allowed %d, want 50", allowed)
	}
}
