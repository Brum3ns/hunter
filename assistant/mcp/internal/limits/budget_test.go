package limits

import (
	"errors"
	"sync"
	"testing"
)

func TestBudgetAcceptsReviewedSixtyFourAndOneHundredTwentyEightCallProfiles(t *testing.T) {
	budget := NewBudget(128, 1<<20, 16<<20)
	for range 128 {
		if err := budget.Reserve("grant", 128, 16<<20); err != nil {
			t.Fatal(err)
		}
		if err := budget.Complete("grant", 0); err != nil {
			t.Fatal(err)
		}
	}
	if err := budget.Reserve("grant", 128, 16<<20); !errors.Is(err, ErrCallsExhausted) {
		t.Fatalf("got %v", err)
	}
	if err := budget.Reserve("other", 0, 16<<20); !errors.Is(err, ErrCallsExhausted) {
		t.Fatalf("got %v", err)
	}
	if err := budget.Reserve("bytes", 1, 0); !errors.Is(err, ErrBytesExhausted) {
		t.Fatalf("got %v", err)
	}
}

func TestBudgetEnforcesPerCallAndTurnByteCeilings(t *testing.T) {
	budget := NewBudget(128, 1<<20, 16<<20)
	if err := budget.Reserve("grant", 64, 16<<20); err != nil {
		t.Fatal(err)
	}
	if err := budget.Complete("grant", (1<<20)+1); !errors.Is(err, ErrBytesExhausted) {
		t.Fatalf("oversized call got %v", err)
	}

	for range 16 {
		if err := budget.Reserve("turn", 64, 16<<20); err != nil {
			t.Fatal(err)
		}
		if err := budget.Complete("turn", 1<<20); err != nil {
			t.Fatal(err)
		}
	}
	if err := budget.Reserve("turn", 64, 16<<20); !errors.Is(err, ErrBytesExhausted) {
		t.Fatalf("turn byte ceiling got %v", err)
	}
}

func TestBudgetReservationsAreConcurrencySafeAndRejectedCallsDoNotConsume(t *testing.T) {
	budget := NewBudget(128, 1<<20, 16<<20)
	var wg sync.WaitGroup
	results := make(chan error, 32)
	for range 32 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results <- budget.Reserve("grant", 128, 16<<20)
		}()
	}
	wg.Wait()
	close(results)
	accepted := 0
	for err := range results {
		if err == nil {
			accepted++
		} else if !errors.Is(err, ErrBytesExhausted) {
			t.Fatalf("unexpected error %v", err)
		}
	}
	if accepted != 16 {
		t.Fatalf("accepted %d reservations, want 16", accepted)
	}
	for range accepted {
		budget.Fail("grant")
	}
	for range 16 {
		if err := budget.Reserve("grant", 128, 16<<20); err != nil {
			t.Fatalf("released reservation was consumed: %v", err)
		}
	}
}
