package limits

import (
	"errors"
	"testing"
)

func TestBudgetStopsAtEightCallsAndRemoteLimits(t *testing.T) {
	budget := NewBudget(8)
	for range 8 {
		if err := budget.Reserve("grant", 8, 1024); err != nil {
			t.Fatal(err)
		}
	}
	if err := budget.Reserve("grant", 8, 1024); !errors.Is(err, ErrCallsExhausted) {
		t.Fatalf("got %v", err)
	}
	if err := budget.Reserve("other", 0, 1024); !errors.Is(err, ErrCallsExhausted) {
		t.Fatalf("got %v", err)
	}
	if err := budget.Reserve("bytes", 1, 0); !errors.Is(err, ErrBytesExhausted) {
		t.Fatalf("got %v", err)
	}
}
