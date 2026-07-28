package runner

import (
	"context"
	"errors"
	"testing"
	"time"

	targets "hunter.local/assistant/mcp/internal/modules/targets"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/transport"
)

func newTargetsRunner(b Backend) *Runner {
	reg := NewRegistry()
	reg.Add(targets.Module{})
	return New(b, reg, redact.NewChecker(64<<10))
}

func TestListTargetsDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_targets"}, ReadScopes: nil,
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 4096,
	}}
	_, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "list_targets", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestListTargetsAllowedWithScope(t *testing.T) {
	payload := []byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":0,"page":1,"limit":50,"items":[]}`)
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"list_targets"}, ReadScopes: []string{"targets"},
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 4096,
	}, payload: payload}
	out, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "list_targets", []byte(`{"q":"example.com"}`))
	if err != nil || string(out) != string(payload) {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

func TestGetTargetDeniedWithoutScope(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{
		Tools: []string{"get_target"}, ReadScopes: []string{"cves"}, // wrong scope
		ExpiresAt: time.Now().Add(time.Minute), CallsRemaining: 8, BytesRemaining: 4096,
	}}
	_, err := newTargetsRunner(b).Dispatch(context.Background(), "g", "get_target", []byte(`{"id":"t1"}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}
