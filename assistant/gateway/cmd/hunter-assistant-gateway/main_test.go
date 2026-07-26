package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
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
