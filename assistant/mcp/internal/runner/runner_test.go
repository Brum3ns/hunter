package runner

import (
	"context"
	"errors"
	"testing"

	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
	"hunter.local/assistant/mcp/internal/transport"
)

type fakeBackend struct {
	payload []byte
	doErr   error
	calls   int
	method  string
	path    string
	body    []byte
}

func (f *fakeBackend) Do(_ context.Context, method, path string, body []byte) ([]byte, error) {
	f.calls++
	f.method = method
	f.path = path
	f.body = append([]byte(nil), body...)
	return f.payload, f.doErr
}

type staticModule struct{ t tool.Tool }

func (m staticModule) Tools() []tool.Tool { return []tool.Tool{m.t} }

func passTool(t tool.Tool) tool.Tool {
	if t.Decode == nil {
		t.Decode = func([]byte) (tool.Request, error) { return tool.Request{}, nil }
	}
	if t.BuildRequest == nil {
		t.BuildRequest = func(tool.Request) (tool.Call, error) {
			return tool.Call{Method: "GET", Path: "/api/v1/assistant/machine/fixed"}, nil
		}
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

func TestDispatchUsesOnlyTheRegisteredFixedRequestWithoutIntrospection(t *testing.T) {
	b := &fakeBackend{payload: []byte(`{"ok":true}`)}
	tl := tool.Tool{
		Name: "list_x",
		Decode: func(raw []byte) (tool.Request, error) {
			if string(raw) != `{"q":"safe"}` {
				return tool.Request{}, errors.New("unexpected input")
			}
			return tool.Request{Payload: "decoded"}, nil
		},
		BuildRequest: func(request tool.Request) (tool.Call, error) {
			if request.Payload != "decoded" {
				return tool.Call{}, errors.New("unexpected request")
			}
			return tool.Call{Method: "POST", Path: "/api/v1/assistant/machine/fixed", Body: []byte(`{"safe":true}`)}, nil
		},
	}

	out, err := newRunner(b, tl).Dispatch(context.Background(), "list_x", []byte(`{"q":"safe"}`))
	if err != nil || string(out) != `{"ok":true}` {
		t.Fatalf("Dispatch: out=%q err=%v", out, err)
	}
	if b.calls != 1 || b.method != "POST" || b.path != "/api/v1/assistant/machine/fixed" || string(b.body) != `{"safe":true}` {
		t.Fatalf("backend call=%d %s %s %s", b.calls, b.method, b.path, b.body)
	}
}

func TestDispatchRejectsUnknownInvalidAndMissingResourceBeforeBackendIO(t *testing.T) {
	b := &fakeBackend{payload: []byte(`{}`)}
	invalid := tool.Tool{Name: "known", Decode: func([]byte) (tool.Request, error) {
		return tool.Request{}, errors.New("invalid")
	}}
	r := newRunner(b, invalid)
	if _, err := r.Dispatch(context.Background(), "unknown", []byte(`{}`)); !errors.Is(err, ErrUnknownTool) {
		t.Fatalf("unknown: %v", err)
	}
	if _, err := r.Dispatch(context.Background(), "known", []byte(`{"extra":1}`)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("invalid: %v", err)
	}

	requires := newRunner(b, tool.Tool{Name: "resource", RequiresResource: true})
	if _, err := requires.Dispatch(context.Background(), "resource", []byte(`{}`)); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("resource: %v", err)
	}
	if b.calls != 0 {
		t.Fatalf("backend calls=%d, want zero", b.calls)
	}
}

func TestDispatchPropagatesCancellationAndStableHunterOutcomes(t *testing.T) {
	cancelled := &fakeBackend{doErr: context.Canceled}
	if _, err := newRunner(cancelled, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "list_x", []byte(`{}`)); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation: %v", err)
	}

	stable := &fakeBackend{doErr: &transport.HunterError{Code: "destination_stale"}}
	_, err := newRunner(stable, tool.Tool{Name: "edit_x"}).Dispatch(context.Background(), "edit_x", []byte(`{}`))
	if got := PublicError(err); got != "destination_stale" {
		t.Fatalf("PublicError=%q", got)
	}

	untrusted := &fakeBackend{doErr: errors.New("attacker controlled backend detail")}
	_, err = newRunner(untrusted, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "list_x", []byte(`{}`))
	if got := PublicError(err); got != "tool_response_rejected" {
		t.Fatalf("PublicError=%q", got)
	}
}

func TestDispatchKeepsResponseSizeRedactionAndClosedOutputValidation(t *testing.T) {
	for name, b := range map[string]*fakeBackend{
		"size":      {payload: make([]byte, (64<<10)+1)},
		"sensitive": {payload: []byte(`{"authorization":"Bearer abcd1234"}`)},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := newRunner(b, tool.Tool{Name: "list_x"}).Dispatch(context.Background(), "list_x", []byte(`{}`)); !errors.Is(err, ErrResponseRejected) {
				t.Fatalf("got %v", err)
			}
		})
	}

	invalidOutput := &fakeBackend{payload: []byte(`{"extra":true}`)}
	tl := tool.Tool{Name: "list_x", Validate: func([]byte) error { return errors.New("closed output") }}
	if _, err := newRunner(invalidOutput, tl).Dispatch(context.Background(), "list_x", []byte(`{}`)); !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("validation: %v", err)
	}
}

func TestDispatchHasNoLocalPerTurnCallState(t *testing.T) {
	b := &fakeBackend{payload: []byte(`{}`)}
	r := newRunner(b, tool.Tool{Name: "list_x"})
	for range 256 {
		if _, err := r.Dispatch(context.Background(), "list_x", []byte(`{}`)); err != nil {
			t.Fatalf("call rejected by local state: %v", err)
		}
	}
}
