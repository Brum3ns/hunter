package runner

import (
	"context"
)

// Backend is the subset of the transport the runner needs (fakeable in tests).
type Backend interface {
	Do(ctx context.Context, method, path string, body []byte) ([]byte, error)
}
