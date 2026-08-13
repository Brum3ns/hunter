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
	"regexp"
	"strings"
	"time"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/tool"
)

var (
	ErrUnexpectedResponse = errors.New("unexpected Hunter response")
	ErrResponseTooLarge   = errors.New("Hunter response too large")
)

const maxErrorResponseBytes int64 = 8 << 10

var stableHunterErrors = map[string]struct{}{
	"name_conflict":                 {},
	"destination_stale":             {},
	"artifact_not_found":            {},
	"validation_failed":             {},
	"control_center_write_disabled": {},
	"authoring_rate_limited":        {},
}

var stableValidationCode = regexp.MustCompile(`\A(?:assistant|ansible|whiterabbit|artifact|expected_lock_version)[a-z0-9_]*\z`)
var grantCorrelationID = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// HunterError carries one reviewed, non-secret machine API outcome. Arbitrary
// response text and unknown error names never cross this boundary.
type HunterError struct {
	Code  string
	Codes []string
}

func (err *HunterError) Error() string { return "Hunter request rejected: " + err.Code }

// Grant is the closed turn-grant introspection response. Read and write scopes
// remain distinct so a write tool can never inherit authority from a read slug.
type Grant struct {
	GrantID        int64           `json:"grant_id"`
	CorrelationID  string          `json:"correlation_id"`
	Tools          []string        `json:"tools"`
	Resources      []tool.Resource `json:"resources"`
	ExpiresAt      time.Time       `json:"expires_at"`
	CallsRemaining int             `json:"calls_remaining"`
	BytesRemaining int             `json:"bytes_remaining"`
	ReadScopes     []string        `json:"read_scopes"`
	WriteScopes    []string        `json:"write_scopes"`
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
	var root map[string]json.RawMessage
	keys := []string{
		"grant_id", "correlation_id", "tools", "resources", "expires_at",
		"calls_remaining", "bytes_remaining", "read_scopes", "write_scopes",
	}
	if codec.DecodeRawClosed(body, &root) != nil || !codec.ExactKeys(root, keys) {
		return Grant{}, ErrUnexpectedResponse
	}
	var result Grant
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&result); err != nil || decoder.Decode(&struct{}{}) != io.EOF ||
		!validGrant(result, root) {
		return Grant{}, ErrUnexpectedResponse
	}
	return result, nil
}

func validGrant(grant Grant, root map[string]json.RawMessage) bool {
	if grant.GrantID <= 0 || !grantCorrelationID.MatchString(grant.CorrelationID) || grant.ExpiresAt.IsZero() ||
		grant.CallsRemaining < 0 || grant.BytesRemaining < 0 ||
		bytes.Equal(bytes.TrimSpace(root["resources"]), []byte("null")) ||
		!validGrantStrings(root["tools"], grant.Tools, 128) ||
		!validGrantStrings(root["read_scopes"], grant.ReadScopes, 128) ||
		!validGrantStrings(root["write_scopes"], grant.WriteScopes, 128) ||
		len(grant.Resources) > 128 {
		return false
	}
	for _, resource := range grant.Resources {
		if !codec.SafeID.MatchString(resource.Type) || !codec.SafeID.MatchString(resource.ID) {
			return false
		}
	}
	return true
}

func validGrantStrings(raw json.RawMessage, values []string, max int) bool {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) || len(values) > max {
		return false
	}
	seen := make(map[string]struct{}, len(values))
	for _, value := range values {
		if !codec.SafeID.MatchString(value) {
			return false
		}
		if _, duplicate := seen[value]; duplicate {
			return false
		}
		seen[value] = struct{}{}
	}
	return true
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
	mediaType, _, err := mime.ParseMediaType(response.Header.Get("Content-Type"))
	if err != nil || mediaType != "application/json" {
		return nil, ErrUnexpectedResponse
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, decodeHunterError(response.Body, response.StatusCode)
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

func decodeHunterError(body io.Reader, status int) error {
	payload, err := io.ReadAll(io.LimitReader(body, maxErrorResponseBytes+1))
	if err != nil || int64(len(payload)) > maxErrorResponseBytes {
		return fmt.Errorf("%w: status %d", ErrUnexpectedResponse, status)
	}
	var root map[string]json.RawMessage
	if json.Unmarshal(payload, &root) != nil {
		return fmt.Errorf("%w: status %d", ErrUnexpectedResponse, status)
	}
	var code string
	if json.Unmarshal(root["error"], &code) != nil {
		return fmt.Errorf("%w: status %d", ErrUnexpectedResponse, status)
	}
	if _, ok := stableHunterErrors[code]; !ok {
		return fmt.Errorf("%w: status %d", ErrUnexpectedResponse, status)
	}
	return &HunterError{Code: code, Codes: decodeValidationCodes(code, root["codes"])}
}

func decodeValidationCodes(code string, raw json.RawMessage) []string {
	if code != "validation_failed" {
		return nil
	}
	var candidates []string
	if json.Unmarshal(raw, &candidates) != nil {
		return nil
	}
	result := make([]string, 0, min(len(candidates), 8))
	seen := make(map[string]struct{}, len(candidates))
	for _, candidate := range candidates {
		if len(result) == 8 {
			break
		}
		if len(candidate) == 0 || len(candidate) > 80 || !stableValidationCode.MatchString(candidate) {
			continue
		}
		if _, exists := seen[candidate]; exists {
			continue
		}
		seen[candidate] = struct{}{}
		result = append(result, candidate)
	}
	return result
}
