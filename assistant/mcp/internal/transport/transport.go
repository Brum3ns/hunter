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
)

var (
	ErrUnexpectedResponse = errors.New("unexpected Hunter response")
	ErrResponseTooLarge   = errors.New("Hunter response too large")
)

const maxErrorResponseBytes int64 = 8 << 10

var stableHunterErrors = map[string]struct{}{
	"capability_disabled":           {},
	"scope_not_granted":             {},
	"turn_grant_expired":            {},
	"turn_call_budget_exhausted":    {},
	"effect_rate_limited":           {},
	"version_conflict":              {},
	"idempotent_replay":             {},
	"not_found":                     {},
	"conflict":                      {},
	"upstream_unavailable":          {},
	"tool_response_rejected":        {},
	"name_conflict":                 {},
	"destination_stale":             {},
	"artifact_not_found":            {},
	"validation_failed":             {},
	"control_center_write_disabled": {},
	"authoring_rate_limited":        {},
}

var stableValidationCode = regexp.MustCompile(`\A(?:assistant|ansible|whiterabbit|artifact|expected_lock_version)[a-z0-9_]*\z`)

// HunterError carries one reviewed, non-secret machine API outcome. Arbitrary
// response text and unknown error names never cross this boundary.
type HunterError struct {
	Code  string
	Codes []string
}

func (err *HunterError) Error() string { return "Hunter request rejected: " + err.Code }

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

// Do performs an authenticated machine-namespace request. body is nil for GET.
func (client *Client) Do(ctx context.Context, method, path string, body []byte) ([]byte, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, client.baseURL+path, reader)
	if err != nil {
		return nil, ErrUnexpectedResponse
	}
	request.Header.Set("Authorization", "Bearer "+client.serviceToken)
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
