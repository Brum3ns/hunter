package turn

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/gateway/internal/provider"
)

type stubGenerator struct{}

func (stubGenerator) Handle(context.Context, string, provider.Request, provider.ToolExecutor) provider.HandleEvent {
	return provider.HandleEvent{Result: &provider.Result{
		Envelope: provider.Envelope{Kind: "assistant_message", Body: "hello"},
		Usage:    provider.Usage{InputTokens: 1, OutputTokens: 1},
	}}
}

type stubToolSession struct{}

func (stubToolSession) Call(context.Context, string, []byte) ([]byte, error) { return nil, nil }
func (stubToolSession) Close() error                                         { return nil }

func stubConnect(context.Context, string) (ToolSession, error) {
	return stubToolSession{}, nil
}

// newTestHandler builds a turn handler wired to a stub Generator and a
// stub MCPConnect, ready-gated by the ready parameter, and bound to the
// bearer token supplied by the caller.
func newTestHandler(t *testing.T, ingressToken string) http.Handler {
	t.Helper()
	var ready atomic.Bool
	ready.Store(true)
	processor := &Processor{Gateway: stubGenerator{}, Connect: stubConnect}
	return NewTurnHandler(HandlerOptions{
		Processor:      processor,
		IngressToken:   ingressToken,
		AllowedHosts:   []string{"assistant-gateway:8081"},
		AllowedOrigins: []string{},
		MaxConcurrent:  2,
		Ready:          &ready,
		Now:            time.Now,
	})
}

// newNotReadyTestHandler mirrors newTestHandler but with ready=false, for
// the 503-not-ready case.
func newNotReadyTestHandler(t *testing.T, ingressToken string) http.Handler {
	t.Helper()
	var ready atomic.Bool
	processor := &Processor{Gateway: stubGenerator{}, Connect: stubConnect}
	return NewTurnHandler(HandlerOptions{
		Processor:      processor,
		IngressToken:   ingressToken,
		AllowedHosts:   []string{"assistant-gateway:8081"},
		AllowedOrigins: []string{},
		MaxConcurrent:  2,
		Ready:          &ready,
		Now:            time.Now,
	})
}

func validEnvelopeJSON(t *testing.T) string {
	t.Helper()
	return string(validTurnJob(t))
}

func TestTurnHandlerRejectsMissingBearer(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "assistant-gateway:8081"
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", recorder.Code)
	}
}

func TestTurnHandlerRejectsUnknownHost(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "evil.example.com"
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", recorder.Code)
	}
}

func TestTurnHandlerReturnsEventsWithoutProgressKind(t *testing.T) {
	handler := newTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "assistant-gateway:8081"
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		SchemaVersion int                     `json:"schema_version"`
		Events        []struct{ Kind string } `json:"events"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body.SchemaVersion != 1 {
		t.Fatalf("schema_version = %d, want 1", body.SchemaVersion)
	}
	for _, event := range body.Events {
		if event.Kind == "progress" {
			t.Fatal("progress events must no longer be emitted")
		}
	}
}

func TestTurnHandlerReturns503WhenNotReady(t *testing.T) {
	handler := newNotReadyTestHandler(t, "secret-token")
	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader(validEnvelopeJSON(t)))
	request.Host = "assistant-gateway:8081"
	request.Header.Set("Authorization", "Bearer secret-token")
	recorder := httptest.NewRecorder()

	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", recorder.Code)
	}
}
