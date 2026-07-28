package runner

import (
	"context"

	"hunter.local/assistant/mcp/internal/transport"
)

// Backend is the subset of the transport the runner needs (fakeable in tests).
type Backend interface {
	Introspect(ctx context.Context, grant string) (transport.Grant, error)
	Do(ctx context.Context, method, path, grant string, body []byte) ([]byte, error)
}
