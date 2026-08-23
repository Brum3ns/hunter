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
	ErrNoReservation  = errors.New("budget reservation not found")
)

type state struct {
	calls        int
	returned     int
	reservations int
}

type Budget struct {
	mu           sync.Mutex
	maxCalls     int
	maxCallBytes int
	maxTurnBytes int
	states       map[[sha256.Size]byte]state
}

func NewBudget(maxCalls int, byteLimits ...int) *Budget {
	maxCallBytes := 1 << 20
	maxTurnBytes := 16 << 20
	if len(byteLimits) == 2 {
		maxCallBytes = byteLimits[0]
		maxTurnBytes = byteLimits[1]
	}
	return &Budget{
		maxCalls: maxCalls, maxCallBytes: maxCallBytes, maxTurnBytes: maxTurnBytes,
		states: make(map[[sha256.Size]byte]state),
	}
}

func (budget *Budget) Reserve(grant string, remoteCalls, remoteBytes int) error {
	if remoteCalls <= 0 || remoteCalls > budget.maxCalls {
		return ErrCallsExhausted
	}
	if remoteBytes < budget.maxCallBytes {
		return ErrBytesExhausted
	}

	digest := sha256.Sum256([]byte(grant))
	budget.mu.Lock()
	defer budget.mu.Unlock()
	current, exists := budget.states[digest]
	if current.calls >= budget.maxCalls {
		return ErrCallsExhausted
	}
	if current.returned+(current.reservations+1)*budget.maxCallBytes > budget.maxTurnBytes {
		return ErrBytesExhausted
	}
	if !exists && len(budget.states) >= 4096 {
		return ErrCapacity
	}
	current.calls++
	current.reservations++
	budget.states[digest] = current
	return nil
}

func (budget *Budget) Complete(grant string, bytes int) error {
	digest := sha256.Sum256([]byte(grant))
	budget.mu.Lock()
	defer budget.mu.Unlock()
	current, exists := budget.states[digest]
	if !exists || current.reservations == 0 {
		return ErrNoReservation
	}
	current.reservations--
	if bytes < 0 || bytes > budget.maxCallBytes || current.returned+bytes > budget.maxTurnBytes {
		budget.states[digest] = current
		return ErrBytesExhausted
	}
	current.returned += bytes
	budget.states[digest] = current
	return nil
}

func (budget *Budget) Fail(grant string) {
	digest := sha256.Sum256([]byte(grant))
	budget.mu.Lock()
	defer budget.mu.Unlock()
	current, exists := budget.states[digest]
	if !exists || current.reservations == 0 {
		return
	}
	current.reservations--
	budget.states[digest] = current
}
