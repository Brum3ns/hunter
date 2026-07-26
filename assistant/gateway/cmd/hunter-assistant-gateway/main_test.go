package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"hunter.local/assistant/gateway/internal/provider"
)

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

func TestServeHealthOnlyBlocksUntilContextCancelledThenShutsDown(t *testing.T) {
	var ready atomic.Bool
	healthServer := &http.Server{Addr: "127.0.0.1:0", Handler: newHealthHandler(&ready)}
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		serveHealthOnly(ctx, healthServer)
		close(done)
	}()

	select {
	case <-done:
		t.Fatal("serveHealthOnly returned before the context was cancelled")
	case <-time.After(50 * time.Millisecond):
	}

	cancel()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("serveHealthOnly did not return after the context was cancelled")
	}

	if ready.Load() {
		t.Fatal("idle path must never report ready")
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
