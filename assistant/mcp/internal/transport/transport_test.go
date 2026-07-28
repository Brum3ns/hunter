package transport

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func newTestClient(t *testing.T, url string, maxBytes int64) *Client {
	t.Helper()
	c, err := NewClient(url, "svc-token", 5*time.Second, maxBytes)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	return c
}

func TestDoSendsServiceAndGrantHeaders(t *testing.T) {
	var gotPath string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.EscapedPath()
		if r.Header.Get("Authorization") != "Bearer svc-token" || r.Header.Get("X-Hunter-Turn-Grant") != "g1" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true}`))
	}))
	defer server.Close()

	body, err := newTestClient(t, server.URL, 64<<10).Do(context.Background(), http.MethodGet, "/api/v1/assistant/machine/contexts/target/a%2Fb", "g1", nil)
	if err != nil || string(body) != `{"ok":true}` {
		t.Fatalf("Do: %q err=%v", body, err)
	}
	if gotPath != "/api/v1/assistant/machine/contexts/target/a%2Fb" {
		t.Fatalf("path=%q", gotPath)
	}
}

func TestIntrospectRejectsUnknownFields(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"grant_id":1,"surprise":2}`))
	}))
	defer server.Close()
	if _, err := newTestClient(t, server.URL, 64<<10).Introspect(context.Background(), "g1"); err == nil {
		t.Fatal("expected unknown-field rejection")
	}
}

func TestDoRefusesRedirectAndHTML(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer ok.Close()

	redirect := httptest.NewServer(http.RedirectHandler(ok.URL, http.StatusFound))
	defer redirect.Close()
	if _, err := newTestClient(t, redirect.URL, 64<<10).Do(context.Background(), http.MethodGet, "/x", "g1", nil); !errors.Is(err, ErrUnexpectedResponse) {
		t.Fatalf("redirect got %v", err)
	}

	html := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte("<html>not json</html>"))
	}))
	defer html.Close()
	if _, err := newTestClient(t, html.URL, 64<<10).Do(context.Background(), http.MethodGet, "/x", "g1", nil); !errors.Is(err, ErrUnexpectedResponse) {
		t.Fatalf("html got %v", err)
	}
}

func TestDoCapsResponseAndHonorsCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/large" {
			_, _ = w.Write(make([]byte, 65))
			return
		}
		<-r.Context().Done()
	}))
	defer server.Close()

	client := newTestClient(t, server.URL, 64)
	if _, err := client.Do(context.Background(), http.MethodGet, "/large", "g1", nil); !errors.Is(err, ErrResponseTooLarge) {
		t.Fatalf("large got %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := client.Do(ctx, http.MethodGet, "/hang", "g1", nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation got %v", err)
	}
}

func TestNewClientRejectsBadURLs(t *testing.T) {
	for _, bad := range []string{"ftp://x", "http://h/path", "http://h?q=1", "", "http://user@h"} {
		if _, err := NewClient(bad, "t", time.Second, 1); err == nil {
			t.Errorf("expected rejection for %q", bad)
		}
	}
}
