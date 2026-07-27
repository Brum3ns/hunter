package main

import (
	"context"
	"encoding/json"
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
		blockUntilShutdown(ctx, &ready, turnServer)
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

// Shutdown must flip readiness off before the server stops, so a request that
// races the shutdown is answered 503 rather than being let through to a
// process on its way out.
func TestBlockUntilShutdownClearsReadyBeforeShuttingDown(t *testing.T) {
	var ready atomic.Bool
	ready.Store(true)
	turnServer := &http.Server{Addr: "127.0.0.1:0", Handler: newHealthHandler(&ready)}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	blockUntilShutdown(ctx, &ready, turnServer)

	if ready.Load() {
		t.Fatal("readiness must be cleared before shutdown")
	}
}

// The idle gateway — no usable provider credential, which is the default on a
// fresh compose up — must still route POST /turns to the handler, so the
// caller gets the JSON gateway_not_ready envelope. Leaving the route unmounted
// would return Go's plain-text 404, which Rails cannot parse as an error
// envelope, turning "gateway not ready" into an opaque decode failure.
func TestIdleServeMuxStillRoutesTurnsAndReportsNotReady(t *testing.T) {
	t.Setenv("ASSISTANT_GATEWAY_ALLOWED_HOSTS", "assistant-gateway:8081")
	var ready atomic.Bool
	mux := newServeMux(&ready, nil, "secret-token")

	request := httptest.NewRequest(http.MethodPost, "/turns", strings.NewReader("{}"))
	request.Host = "assistant-gateway:8081"
	request.Header.Set("Authorization", "Bearer secret-token")
	response := httptest.NewRecorder()

	mux.ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503: %s", response.Code, response.Body.String())
	}
	var body struct {
		Error struct{ Code string } `json:"error"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &body); err != nil {
		t.Fatalf("idle /turns response was not a JSON error envelope (%q): %v", response.Body.String(), err)
	}
	if body.Error.Code != "gateway_not_ready" {
		t.Fatalf("error code = %q, want %q", body.Error.Code, "gateway_not_ready")
	}
}

func TestServeMuxKeepsHealthzOnTheIdlePath(t *testing.T) {
	var ready atomic.Bool
	mux := newServeMux(&ready, nil, "secret-token")

	response := httptest.NewRecorder()
	mux.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "http://localhost/healthz", nil))

	if response.Code != http.StatusServiceUnavailable || response.Body.Len() != 0 {
		t.Fatalf("status=%d body=%q", response.Code, response.Body.String())
	}
}

func TestSplitListTrimsAndDropsBlankEntries(t *testing.T) {
	for name, testCase := range map[string]struct {
		value string
		want  []string
	}{
		"empty":           {"", nil},
		"single":          {"a:1", []string{"a:1"}},
		"spaced":          {" a:1 , b:2 ", []string{"a:1", "b:2"}},
		"trailing comma":  {"a:1,", []string{"a:1"}},
		"only separators": {",,", []string{}},
		"only whitespace": {"   ", []string{}},
		"internal blank":  {"a:1,,b:2", []string{"a:1", "b:2"}},
	} {
		t.Run(name, func(t *testing.T) {
			got := splitList(testCase.value)
			if len(got) != len(testCase.want) {
				t.Fatalf("splitList(%q) = %v, want %v", testCase.value, got, testCase.want)
			}
			for index := range got {
				if got[index] != testCase.want[index] {
					t.Fatalf("splitList(%q) = %v, want %v", testCase.value, got, testCase.want)
				}
			}
		})
	}
}

func TestIntFromEnvFallsBackOnAnythingUnusable(t *testing.T) {
	for name, testCase := range map[string]struct {
		value string
		want  int
	}{
		"unset":       {"", 2},
		"valid":       {"5", 5},
		"not numeric": {"many", 2},
		"zero":        {"0", 2},
		"negative":    {"-1", 2},
		"float":       {"1.5", 2},
	} {
		t.Run(name, func(t *testing.T) {
			t.Setenv("ASSISTANT_MAX_CONCURRENT_TURNS", testCase.value)
			if got := intFromEnv("ASSISTANT_MAX_CONCURRENT_TURNS", 2); got != testCase.want {
				t.Fatalf("intFromEnv(%q) = %d, want %d", testCase.value, got, testCase.want)
			}
		})
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
