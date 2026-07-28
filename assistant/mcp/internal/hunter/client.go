package hunter

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
)

var (
	ErrUnsupportedTool    = errors.New("unsupported tool route")
	ErrUnexpectedResponse = errors.New("unexpected Hunter response")
	ErrResponseTooLarge   = errors.New("Hunter response too large")
	ErrRequestTooLarge    = errors.New("Hunter request too large")
)

type Resource struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type Grant struct {
	GrantID        int64      `json:"grant_id"`
	CorrelationID  string     `json:"correlation_id"`
	Tools          []string   `json:"tools"`
	Resources      []Resource `json:"resources"`
	ExpiresAt      time.Time  `json:"expires_at"`
	CallsRemaining int        `json:"calls_remaining"`
	BytesRemaining int        `json:"bytes_remaining"`
}

type Client interface {
	Introspect(context.Context, string) (Grant, error)
	Get(context.Context, string, string, string, string) ([]byte, error)
	Post(context.Context, string, string, any) ([]byte, error)
}

type HTTPClient struct {
	baseURL          string
	serviceToken     string
	maxResponseBytes int64
	http             *http.Client
	routes           map[string]func(string, string) string
}

func NewHTTPClient(baseURL, serviceToken string, timeout time.Duration, maxResponseBytes int64) (*HTTPClient, error) {
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

	client := &HTTPClient{
		baseURL:          strings.TrimSuffix(baseURL, "/"),
		serviceToken:     serviceToken,
		maxResponseBytes: maxResponseBytes,
		http: &http.Client{
			Timeout:       timeout,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
	client.routes = map[string]func(string, string) string{
		"get_selected_context": func(resourceType, id string) string {
			return "/api/v1/assistant/machine/contexts/" + url.PathEscape(resourceType) + "/" + url.PathEscape(id)
		},
		"get_artifact_example": func(resourceType, id string) string {
			return "/api/v1/assistant/machine/artifacts/" + url.PathEscape(resourceType) + "/" + url.PathEscape(id)
		},
		"get_authoring_policy": func(resourceType, _ string) string {
			return "/api/v1/assistant/machine/policies/" + url.PathEscape(resourceType)
		},
		"get_validation_result": func(_, id string) string {
			return "/api/v1/assistant/machine/validation_results/" + url.PathEscape(id)
		},
	}
	return client, nil
}

func (client *HTTPClient) Introspect(ctx context.Context, grant string) (Grant, error) {
	body, err := client.request(ctx, http.MethodGet, "/api/v1/assistant/machine/grant", grant, nil)
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

func (client *HTTPClient) Get(ctx context.Context, grant, tool, resourceType, id string) ([]byte, error) {
	route, ok := client.routes[tool]
	if !ok {
		return nil, ErrUnsupportedTool
	}
	return client.request(ctx, http.MethodGet, route(resourceType, id), grant, nil)
}

func (client *HTTPClient) Post(ctx context.Context, grant, tool string, body any) ([]byte, error) {
	artifactType := ""
	switch tool {
	case "validate_whiterabbit_draft":
		artifactType = "whiterabbit_template"
	case "validate_ansible_draft":
		artifactType = "ansible_playbook"
	default:
		return nil, ErrUnsupportedTool
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return nil, errors.New("invalid Hunter request")
	}
	if int64(len(payload)) > 64<<10 {
		return nil, ErrRequestTooLarge
	}
	return client.request(ctx, http.MethodPost, "/api/v1/assistant/machine/validations/"+artifactType, grant, payload)
}

func (client *HTTPClient) request(ctx context.Context, method, path, grant string, body []byte) ([]byte, error) {
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
