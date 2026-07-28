// Package transport is the generic authenticated client to the Hunter machine
// namespace. Modules build a tool.Call describing the path; this package runs it.
package transport

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"time"

	"hunter.local/assistant/mcp/internal/tool"
)

var (
	ErrUnexpectedResponse = errors.New("unexpected Hunter response")
	ErrResponseTooLarge   = errors.New("Hunter response too large")
)

// Grant is the turn-grant introspection response. ReadScopes is Phase-2 forward
// wiring: Rails omits it today, so DisallowUnknownFields decodes it to nil.
type Grant struct {
	GrantID        int64           `json:"grant_id"`
	CorrelationID  string          `json:"correlation_id"`
	Tools          []string        `json:"tools"`
	Resources      []tool.Resource `json:"resources"`
	ExpiresAt      time.Time       `json:"expires_at"`
	CallsRemaining int             `json:"calls_remaining"`
	BytesRemaining int             `json:"bytes_remaining"`
	ReadScopes     []string        `json:"read_scopes"`
}

type Client struct {
	baseURL          string
	serviceToken     string
	maxResponseBytes int64
	http             *http.Client
}

func NewClient(baseURL, serviceToken string, timeout time.Duration, maxResponseBytes int64) (*Client, error) {
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("invalid Hunter base URL")
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return nil, errors.New("Hunter base URL must not contain a path")
	}
	if serviceToken == "" || maxResponseBytes <= 0 {
		return nil, errors.New("invalid Hunter client configuration")
	}

	return &Client{
		baseURL:          strings.TrimSuffix(baseURL, "/"),
		serviceToken:     serviceToken,
		maxResponseBytes: maxResponseBytes,
		http: &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}, nil
}

func (client *Client) Introspect(ctx context.Context, grant string) (Grant, error) {
	body, err := client.Do(ctx, http.MethodGet, "/api/v1/assistant/machine/grant", grant, nil)
	if err != nil {
		return Grant{}, err
	}
	var result Grant
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return Grant{}, ErrUnexpectedResponse
	}
	return result, nil
}

// Do performs an authenticated machine-namespace request. body is nil for GET.
func (client *Client) Do(ctx context.Context, method, path, grant string, body []byte) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, client.baseURL+path, reader)
	if err != nil {
		return nil, ErrUnexpectedResponse
	}
	request.Header.Set("Authorization", "Bearer "+client.serviceToken)
	request.Header.Set("X-Hunter-Turn-Grant", grant)
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}

	response, err := client.http.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, ErrUnexpectedResponse
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: status %d", ErrUnexpectedResponse, response.StatusCode)
	}
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, ErrUnexpectedResponse
	}
	payload, err := io.ReadAll(io.LimitReader(response.Body, client.maxResponseBytes+1))
	if err != nil {
		return nil, ErrUnexpectedResponse
	}
	if int64(len(payload)) > client.maxResponseBytes {
		return nil, ErrResponseTooLarge
	}
	return payload, nil
}
