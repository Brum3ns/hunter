package main

import (
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestHealthHandlerReturnsStatusOnlyAndRequiresReadiness(t *testing.T) {
	var ready atomic.Bool
	handler := newHealthHandler(&ready)

	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusServiceUnavailable || recorder.Body.Len() != 0 {
		t.Fatalf("unready response=%d body=%q", recorder.Code, recorder.Body.String())
	}

	ready.Store(true)
	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusNoContent || recorder.Body.Len() != 0 || recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("ready response=%d body=%q headers=%v", recorder.Code, recorder.Body.String(), recorder.Header())
	}

	recorder = httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodPost, "/healthz", nil))
	if recorder.Code != http.StatusMethodNotAllowed || recorder.Body.Len() != 0 {
		t.Fatalf("method response=%d body=%q", recorder.Code, recorder.Body.String())
	}
}
