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

func TestToolCatalogVerificationAcceptsReviewedCatalogSuperset(t *testing.T) {
	if err := verifyToolNames(FixedToolNames()); err != nil {
		t.Fatal(err)
	}
	expanded := append(slices.Clone(FixedToolNames()),
		"list_targets", "create_whiterabbit_template", "edit_ansible_playbook")
	if err := verifyToolNames(expanded); err != nil {
		t.Fatalf("rejected modular catalog superset: %v", err)
	}
}

func TestToolCatalogVerificationStillRequiresEachLegacyToolExactlyOnce(t *testing.T) {
	missing := slices.Clone(FixedToolNames()[1:])
	if err := verifyToolNames(missing); err == nil {
		t.Fatal("accepted catalog missing a legacy tool")
	}
	duplicate := append(slices.Clone(FixedToolNames()), FixedToolNames()[0])
	if err := verifyToolNames(duplicate); err == nil {
		t.Fatal("accepted duplicate legacy tool")
	}
}

func TestLegacySessionCannotCallAdvertisedAuthoringTool(t *testing.T) {
	session := &Session{}
	if _, err := session.Call(context.Background(), "create_whiterabbit_template", []byte(`{}`)); err == nil {
		t.Fatal("legacy session accepted an authoring tool")
	}
}
