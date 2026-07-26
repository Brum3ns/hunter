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
