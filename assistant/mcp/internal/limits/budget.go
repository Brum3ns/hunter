package limits

import (
	"crypto/sha256"
	"errors"
	"sync"
)

var (
	ErrCallsExhausted = errors.New("call budget exhausted")
	ErrBytesExhausted = errors.New("byte budget exhausted")
	ErrCapacity       = errors.New("budget tracker capacity exhausted")
)

type Budget struct {
	mu       sync.Mutex
	maxCalls int
	counts   map[[sha256.Size]byte]int
}

func NewBudget(maxCalls int) *Budget {
	return &Budget{maxCalls: maxCalls, counts: make(map[[sha256.Size]byte]int)}
}

func (budget *Budget) Reserve(grant string, remoteCalls, remoteBytes int) error {
	if remoteCalls <= 0 {
		return ErrCallsExhausted
	}
	if remoteBytes <= 0 {
		return ErrBytesExhausted
	}

	digest := sha256.Sum256([]byte(grant))
	budget.mu.Lock()
	defer budget.mu.Unlock()
	if budget.counts[digest] >= budget.maxCalls {
		return ErrCallsExhausted
	}
	if _, exists := budget.counts[digest]; !exists && len(budget.counts) >= 4096 {
		return ErrCapacity
	}
	budget.counts[digest]++
	return nil
}
