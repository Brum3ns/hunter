package provider

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
)

func TestBoundedTransportRejectsOversizedRequestsAndResponses(t *testing.T) {
	called := false
	transport := boundedTransport{
		next: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			called = true
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(strings.Repeat("x", 9))),
				Request:    request,
			}, nil
		}),
		maxRequestBytes:  8,
		maxResponseBytes: 8,
	}
	oversized, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, "https://api.openai.com/v1/responses", strings.NewReader("123456789"))
	if _, err := transport.RoundTrip(oversized); !errors.Is(err, ErrProviderBodyTooLarge) || called {
		t.Fatalf("request err=%v called=%v", err, called)
	}

	request, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, "https://api.openai.com/v1/responses", strings.NewReader("1234"))
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadAll(response.Body); !errors.Is(err, ErrProviderBodyTooLarge) {
		t.Fatalf("response err=%v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

// squid used to be a second enforcement point for provider egress. It is gone, so
// these tests pin the two checks that replaced it: the request URL is vetted by
// boundedTransport, and the address actually dialled is vetted by DialContext.
func TestRestrictedClientRejectsNonProviderDestinations(t *testing.T) {
	client, err := NewRestrictedHTTPClient()
	if err != nil {
		t.Fatalf("NewRestrictedHTTPClient: %v", err)
	}

	for name, target := range map[string]string{
		"unrelated host":     "https://evil.example.com/v1/messages",
		"plaintext provider": "http://api.anthropic.com/v1/messages",
		"odd port":           "https://api.anthropic.com:8443/v1/messages",
		"metadata service":   "https://169.254.169.254/latest/meta-data/",
	} {
		t.Run(name, func(t *testing.T) {
			request, err := http.NewRequest(http.MethodPost, target, strings.NewReader("{}"))
			if err != nil {
				t.Fatalf("NewRequest: %v", err)
			}
			if _, err := client.Transport.RoundTrip(request); err == nil {
				t.Fatalf("RoundTrip accepted %s", target)
			}
		})
	}
}

func TestRestrictedClientDialsOnlyAllowlistedProviderHosts(t *testing.T) {
	client, err := NewRestrictedHTTPClient()
	if err != nil {
		t.Fatalf("NewRestrictedHTTPClient: %v", err)
	}
	bounded, ok := client.Transport.(boundedTransport)
	if !ok {
		t.Fatalf("Transport = %T, want boundedTransport", client.Transport)
	}
	transport, ok := bounded.next.(*http.Transport)
	if !ok {
		t.Fatalf("bounded.next = %T, want *http.Transport", bounded.next)
	}

	// No proxy may be consulted: an HTTPS_PROXY in the container environment must
	// not be able to redirect provider traffic now that squid is gone.
	if transport.Proxy != nil {
		t.Fatal("Proxy must be nil so the environment cannot redirect provider traffic")
	}

	for name, address := range map[string]string{
		"unrelated host":   "evil.example.com:443",
		"wrong port":       "api.anthropic.com:3128",
		"link-local":       "169.254.169.254:443",
		"missing port":     "api.anthropic.com",
		"former squid hop": "assistant-egress:3128",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := transport.DialContext(context.Background(), "tcp", address); err == nil {
				t.Fatalf("DialContext accepted %s", address)
			}
		})
	}
}
