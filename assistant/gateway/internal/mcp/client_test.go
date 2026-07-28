package mcpclient

import (
	"context"
	"io"
	"net/http"
	"slices"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestAuthenticatedTransportAddsOnlyGatewayAndTurnCredentials(t *testing.T) {
	transport := authenticatedTransport{
		next: roundTripFunc(func(request *http.Request) (*http.Response, error) {
			if request.Header.Get("Authorization") != "Bearer gateway-token" || request.Header.Get("X-Hunter-Turn-Grant") != "turn-grant" {
				t.Fatal("credentials missing")
			}
			if request.Header.Get("X-Hunter-Service-Token") != "" {
				t.Fatal("Hunter service credential leaked from gateway")
			}
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     make(http.Header),
				Body:       io.NopCloser(strings.NewReader(`{}`)),
				Request:    request,
			}, nil
		}),
		gatewayToken: "gateway-token",
		turnGrant:    "turn-grant",
	}
	request, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, "http://hunter-mcp:8080/mcp", strings.NewReader(`{}`))
	if _, err := transport.RoundTrip(request); err != nil {
		t.Fatal(err)
	}
}

func TestToolCatalogVerificationRejectsAnyExpansion(t *testing.T) {
	if err := verifyToolNames(FixedToolNames()); err != nil {
		t.Fatal(err)
	}
	expanded := append(slices.Clone(FixedToolNames()), "shell")
	if err := verifyToolNames(expanded); err == nil {
		t.Fatal("accepted expanded MCP catalog")
	}
}
