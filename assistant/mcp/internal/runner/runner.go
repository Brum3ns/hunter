package runner

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"hunter.local/assistant/mcp/internal/limits"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/transport"
)

var (
	ErrUnknownTool         = errors.New("unknown tool")
	ErrInvalidInput        = errors.New("invalid tool input")
	ErrToolDenied          = errors.New("tool not granted")
	ErrResourceDenied      = errors.New("resource not granted")
	ErrScopeDenied         = errors.New("scope not granted")
	ErrGrantExpired        = errors.New("turn grant expired")
	ErrCallBudgetExhausted = errors.New("turn call budget exhausted")
	ErrResponseRejected    = errors.New("tool response rejected")
)

// Runner owns the whole cross-cutting tool pipeline: grant introspection,
// authorization (tool, scope, resource), budget, dispatch, redaction, and
// closed output validation. Modules supply only per-tool Decode/Build/Validate.
type Runner struct {
	backend  Backend
	registry *Registry
	checker  *redact.Checker
	budget   *limits.Budget
}

func New(backend Backend, registry *Registry, checker *redact.Checker) *Runner {
	if checker == nil {
		checker = redact.NewChecker(512 << 10)
	}
	return &Runner{
		backend: backend, registry: registry, checker: checker,
		budget: limits.NewBudget(128, 1<<20, 16<<20),
	}
}

func (r *Runner) Dispatch(ctx context.Context, rawGrant, name string, args []byte) ([]byte, error) {
	if rawGrant == "" {
		return nil, ErrToolDenied
	}
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

	grant, err := r.backend.Introspect(ctx, rawGrant)
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
	if !grant.ExpiresAt.After(time.Now()) {
		return nil, ErrGrantExpired
	}
	if !slices.Contains(grant.Tools, name) {
		return nil, ErrToolDenied
	}
	grantedScopes := grant.ReadScopes
	if t.WriteScope {
		grantedScopes = grant.WriteScopes
	}
	if t.Scope != "" && !slices.Contains(grantedScopes, t.Scope) {
		return nil, ErrScopeDenied
	}
	if req.Resource != nil && !slices.Contains(grant.Resources, *req.Resource) {
		return nil, ErrResourceDenied
	}
	call, err := t.BuildRequest(req)
	if err != nil {
		return nil, ErrInvalidInput
	}
	if err := r.budget.Reserve(rawGrant, grant.CallsRemaining, grant.BytesRemaining); err != nil {
		if errors.Is(err, limits.ErrCallsExhausted) {
			return nil, ErrCallBudgetExhausted
		}
		return nil, ErrResponseRejected
	}
	payload, err := r.backend.Do(ctx, call.Method, call.Path, rawGrant, call.Body)
	if err != nil {
		r.budget.Fail(rawGrant)
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
		r.budget.Fail(rawGrant)
		return nil, ErrResponseRejected
	}
	if err := r.budget.Complete(rawGrant, len(payload)); err != nil {
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
