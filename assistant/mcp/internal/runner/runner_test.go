package runner

import (
	"context"
	"errors"
	"testing"
	"time"

	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
	"hunter.local/assistant/mcp/internal/transport"
)

type fakeBackend struct {
	grant   transport.Grant
	payload []byte
	doErr   error
}

func (f fakeBackend) Introspect(context.Context, string) (transport.Grant, error) {
	return f.grant, nil
}

func (f fakeBackend) Do(context.Context, string, string, string, []byte) ([]byte, error) {
	return f.payload, f.doErr
}

type staticModule struct{ t tool.Tool }

func (m staticModule) Tools() []tool.Tool { return []tool.Tool{m.t} }

func passTool(t tool.Tool) tool.Tool {
	if t.Decode == nil {
		t.Decode = func([]byte) (tool.Request, error) { return tool.Request{}, nil }
	}
	if t.BuildRequest == nil {
		t.BuildRequest = func(tool.Request) (tool.Call, error) { return tool.Call{Method: "GET", Path: "/p"}, nil }
	}
	if t.Validate == nil {
		t.Validate = func([]byte) error { return nil }
	}
	return t
}

func newRunner(b Backend, t tool.Tool) *Runner {
	reg := NewRegistry()
	reg.Add(staticModule{t: passTool(t)})
	return New(b, reg, redact.NewChecker(64<<10))
}

func liveGrant(g transport.Grant) transport.Grant {
	if g.ExpiresAt.IsZero() {
		g.ExpiresAt = time.Now().Add(time.Minute)
	}
	if g.CallsRemaining == 0 {
		g.CallsRemaining = 8
	}
	if g.BytesRemaining == 0 {
		g.BytesRemaining = 1024
	}
	return g
}

func TestDispatchScopeDenied(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"list_x"}}), payload: []byte(`{"result":1}`)}
	_, err := newRunner(b, tool.Tool{Name: "list_x", Scope: "targets"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`))
	if !errors.Is(err, ErrScopeDenied) {
		t.Fatalf("want ErrScopeDenied, got %v", err)
	}
}

func TestDispatchScopeGrantedHappyPath(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"list_x"}, ReadScopes: []string{"targets"}}), payload: []byte(`{"ok":1}`)}
	out, err := newRunner(b, tool.Tool{Name: "list_x", Scope: "targets"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`))
	if err != nil || string(out) != `{"ok":1}` {
		t.Fatalf("happy path failed: %q %v", out, err)
	}
}

func TestDispatchUnknownAndEmptyGrant(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{})}
	r := newRunner(b, tool.Tool{Name: "list_x"})
	if _, err := r.Dispatch(context.Background(), "", "list_x", []byte(`{}`)); !errors.Is(err, ErrToolDenied) {
		t.Fatalf("empty grant: %v", err)
	}
	if _, err := r.Dispatch(context.Background(), "g", "nope", []byte(`{}`)); !errors.Is(err, ErrUnknownTool) {
		t.Fatalf("unknown tool: %v", err)
	}
}

func TestDispatchExpiredGrant(t *testing.T) {
	b := fakeBackend{grant: transport.Grant{Tools: []string{"list_x"}, ExpiresAt: time.Now().Add(-time.Minute)}}
	if _, err := newRunner(b, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`)); !errors.Is(err, ErrGrantExpired) {
		t.Fatalf("want ErrGrantExpired, got %v", err)
	}
}

func TestDispatchToolNotInGrant(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"other"}})}
	if _, err := newRunner(b, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`)); !errors.Is(err, ErrToolDenied) {
		t.Fatalf("want ErrToolDenied, got %v", err)
	}
}

func TestDispatchResourceDenied(t *testing.T) {
	res := tool.Resource{Type: "target", ID: "denied"}
	tl := tool.Tool{
		Name:             "get_x",
		RequiresResource: true,
		Decode:           func([]byte) (tool.Request, error) { return tool.Request{Resource: &res}, nil },
	}
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"get_x"}, Resources: []tool.Resource{{Type: "target", ID: "allowed"}}})}
	if _, err := newRunner(b, tl).Dispatch(context.Background(), "g", "get_x", []byte(`{}`)); !errors.Is(err, ErrResourceDenied) {
		t.Fatalf("want ErrResourceDenied, got %v", err)
	}
}

func TestDispatchRequiresResourceButNoneDecoded(t *testing.T) {
	tl := tool.Tool{Name: "get_x", RequiresResource: true} // Decode returns empty Request (nil resource)
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"get_x"}})}
	if _, err := newRunner(b, tl).Dispatch(context.Background(), "g", "get_x", []byte(`{}`)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("want ErrInvalidInput, got %v", err)
	}
}

func TestDispatchCancellationPropagates(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"list_x"}}), doErr: context.Canceled}
	if _, err := newRunner(b, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`)); !errors.Is(err, context.Canceled) {
		t.Fatalf("want context.Canceled, got %v", err)
	}
}

func TestDispatchPreservesStableHunterOutcome(t *testing.T) {
	b := fakeBackend{
		grant: liveGrant(transport.Grant{Tools: []string{"edit_x"}}),
		doErr: &transport.HunterError{Code: "destination_stale"},
	}
	_, err := newRunner(b, tool.Tool{Name: "edit_x"}).Dispatch(context.Background(), "g", "edit_x", []byte(`{}`))
	if got := PublicError(err); got != "destination_stale" {
		t.Fatalf("PublicError = %q, want destination_stale", got)
	}
}

func TestDispatchValidateRejection(t *testing.T) {
	tl := tool.Tool{Name: "list_x", Validate: func([]byte) error { return errors.New("bad output") }}
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"list_x"}}), payload: []byte(`{"ok":1}`)}
	if _, err := newRunner(b, tl).Dispatch(context.Background(), "g", "list_x", []byte(`{}`)); !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("want ErrResponseRejected, got %v", err)
	}
}

func TestDispatchRedactionRejection(t *testing.T) {
	b := fakeBackend{grant: liveGrant(transport.Grant{Tools: []string{"list_x"}}), payload: []byte(`{"authorization":"Bearer abcd1234"}`)}
	if _, err := newRunner(b, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "g", "list_x", []byte(`{}`)); !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("want ErrResponseRejected on redaction, got %v", err)
	}
}
