package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/gateway/internal/config"
	"hunter.local/assistant/gateway/internal/provider"
)

func setMachineTokens(t *testing.T) {
	t.Helper()
	t.Setenv("ASSISTANT_GATEWAY_MCP_TOKEN", strings.Repeat("m", 32))
	t.Setenv("ASSISTANT_GATEWAY_INGRESS_TOKEN", strings.Repeat("i", 32))
}

func TestHealthHandlerReturnsStatusOnly(t *testing.T) {
	var ready atomic.Bool
	handler := newHealthHandler(&ready)

	request := httptest.NewRequest(http.MethodGet, "http://localhost/healthz", nil)
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusServiceUnavailable || response.Body.Len() != 0 {
		t.Fatalf("not ready status=%d body=%q", response.Code, response.Body.String())
	}

	ready.Store(true)
	response = httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusNoContent || response.Body.Len() != 0 {
		t.Fatalf("ready status=%d body=%q", response.Code, response.Body.String())
	}
}

func TestBlockUntilShutdownBlocksUntilContextCancelledThenShutsDown(t *testing.T) {
	var ready atomic.Bool
	turnServer := &http.Server{Addr: "127.0.0.1:0", Handler: newHealthHandler(&ready)}
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		blockUntilShutdown(ctx, turnServer)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("blockUntilShutdown returned before the context was cancelled")
	case <-time.After(50 * time.Millisecond):
	}

	cancel()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("blockUntilShutdown did not return after the context was cancelled")
	}

	if ready.Load() {
		t.Fatal("idle path must never report ready")
	}
}

// A provider key whose value contains an internal space is classified
// "valid" by config.ProviderStatus (matching Rails' preflight) but rejected
// by the stricter runtime SecretResolver.Resolve. That divergence must
// disable the one provider, not exit the process, or a corrupt key
// crash-loops the container under restart: unless-stopped.
func TestAMalformedKeyReportedAvailableIsDroppedRatherThanExiting(t *testing.T) {
	setMachineTokens(t)
	t.Setenv("ASSISTANT_ANTHROPIC_API_KEY", "sk-live with-an-internal-space")
	t.Setenv("ASSISTANT_OPENAI_API_KEY", "")

	if got := config.ProviderStatus("sk-live with-an-internal-space", true); got != "valid" {
		t.Fatalf("precondition: expected the malformed key to report valid, got %q", got)
	}
	settings, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	openAIAdapter, anthropicAdapter, active := resolveAdapters(settings, &http.Client{})
	if len(active) != 0 {
		t.Fatalf("expected the malformed profile to be dropped, got active=%v", active)
	}
	if openAIAdapter != nil || anthropicAdapter != nil {
		t.Fatal("no adapter may be built from a credential that failed to resolve")
	}
}

func TestAMalformedKeyDoesNotDisableAWorkingProvider(t *testing.T) {
	setMachineTokens(t)
	t.Setenv("ASSISTANT_ANTHROPIC_API_KEY", "sk-live with-an-internal-space")
	t.Setenv("ASSISTANT_OPENAI_API_KEY", "sk-live-openai")

	settings, err := config.Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	openAIAdapter, anthropicAdapter, active := resolveAdapters(settings, &http.Client{})
	if len(active) != 1 || active[0] != "openai_primary" {
		t.Fatalf("expected only openai_primary to survive, got %v", active)
	}
	if openAIAdapter == nil {
		t.Fatal("the working provider must still get an adapter")
	}
	if anthropicAdapter != nil {
		t.Fatal("the malformed provider must not get an adapter")
	}
}

func TestGatewayDispatchTreatsAMissingAdapterAsAStableErrorNotAPanic(t *testing.T) {
	gateway := provider.NewGateway(nil, nil)

	for _, providerName := range []string{"openai", "anthropic"} {
		event := gateway.Handle(context.Background(), providerName, provider.Request{}, nil)
		if event.Code != "provider_not_allowed" || event.Result != nil {
			t.Fatalf("provider=%s event=%+v", providerName, event)
		}
	}
}
