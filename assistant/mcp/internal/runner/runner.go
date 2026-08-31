package runner

import (
	"context"
	"errors"
	"strings"

	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/transport"
)

var (
	ErrUnknownTool      = errors.New("unknown tool")
	ErrInvalidInput     = errors.New("invalid tool input")
	ErrResponseRejected = errors.New("tool response rejected")
)

// Runner owns the cross-cutting tool pipeline: fixed registry lookup, closed
// input decoding, request construction, dispatch, redaction, and closed output
// validation. Modules supply only per-tool Decode/Build/Validate.
type Runner struct {
	backend  Backend
	registry *Registry
	checker  *redact.Checker
}

func New(backend Backend, registry *Registry, checker *redact.Checker) *Runner {
	if checker == nil {
		checker = redact.NewChecker(512 << 10)
	}
	return &Runner{backend: backend, registry: registry, checker: checker}
}

func (r *Runner) Dispatch(ctx context.Context, name string, args []byte) ([]byte, error) {
	t, ok := r.registry.Lookup(name)
	if !ok {
		return nil, ErrUnknownTool
	}
	req, err := t.Decode(args)
	if err != nil {
		return nil, ErrInvalidInput
	}
	if t.RequiresResource && req.Resource == nil {
		return nil, ErrInvalidInput
	}

	call, err := t.BuildRequest(req)
	if err != nil {
		return nil, ErrInvalidInput
	}
	payload, err := r.backend.Do(ctx, call.Method, call.Path, call.Body)
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil, err
		}
		var hunterErr *transport.HunterError
		if errors.As(err, &hunterErr) {
			return nil, hunterErr
		}
		return nil, ErrResponseRejected
	}
	if r.checker.Check(payload) != nil || t.Validate(payload) != nil {
		return nil, ErrResponseRejected
	}
	return payload, nil
}

func stableHunterCode(err error) (string, bool) {
	var hunterErr *transport.HunterError
	if !errors.As(err, &hunterErr) {
		return "", false
	}
	if hunterErr.Code == "validation_failed" && len(hunterErr.Codes) > 0 {
		return hunterErr.Code + ": " + strings.Join(hunterErr.Codes, ", "), true
	}
	return hunterErr.Code, true
}
