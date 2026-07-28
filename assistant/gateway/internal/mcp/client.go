package mcpclient

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"hunter.local/assistant/gateway/internal/config"
)

var ErrMCPRejected = errors.New("MCP request rejected")

type Client struct {
	gatewayToken string
	baseClient   *http.Client
	endpoint     string
}

type Session struct {
	session *mcp.ClientSession
}

func New(gatewayToken string) (*Client, error) {
	if !validCredential(gatewayToken) {
		return nil, ErrMCPRejected
	}
	return &Client{
		gatewayToken: gatewayToken,
		baseClient: &http.Client{
			Timeout:       20 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		endpoint: config.MCPURL,
	}, nil
}

func (client *Client) Connect(ctx context.Context, turnGrant string) (*Session, error) {
	if !validCredential(turnGrant) {
		return nil, ErrMCPRejected
	}
	httpClient := *client.baseClient
	next := httpClient.Transport
	if next == nil {
		next = http.DefaultTransport
	}
	httpClient.Transport = authenticatedTransport{next: next, gatewayToken: client.gatewayToken, turnGrant: turnGrant}
	transport := &mcp.StreamableClientTransport{
		Endpoint:             client.endpoint,
		HTTPClient:           &httpClient,
		MaxRetries:           -1,
		DisableStandaloneSSE: true,
	}
	mcpClient := mcp.NewClient(
		&mcp.Implementation{Name: "hunter-assistant-gateway", Version: "1.0.0"},
		&mcp.ClientOptions{Capabilities: &mcp.ClientCapabilities{}},
	)
	session, err := mcpClient.Connect(ctx, transport, nil)
	if err != nil {
		return nil, ErrMCPRejected
	}
	tools, err := session.ListTools(ctx, nil)
	if err != nil {
		_ = session.Close()
		return nil, ErrMCPRejected
	}
	names := make([]string, 0, len(tools.Tools))
	for _, tool := range tools.Tools {
		names = append(names, tool.Name)
	}
	if err := verifyToolNames(names); err != nil {
		_ = session.Close()
		return nil, err
	}
	return &Session{session: session}, nil
}

func (session *Session) Call(ctx context.Context, name string, arguments []byte) ([]byte, error) {
	if !slices.Contains(FixedToolNames(), name) || len(arguments) == 0 || len(arguments) > 64<<10 || !json.Valid(arguments) {
		return nil, ErrMCPRejected
	}
	var decoded map[string]any
	if err := json.Unmarshal(arguments, &decoded); err != nil {
		return nil, ErrMCPRejected
	}
	result, err := session.session.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: decoded})
	if err != nil || result.IsError || result.StructuredContent == nil {
		return nil, ErrMCPRejected
	}
	payload, err := json.Marshal(result.StructuredContent)
	if err != nil || len(payload) == 0 || len(payload) > 64<<10 {
		return nil, ErrMCPRejected
	}
	return payload, nil
}

func (session *Session) Close() error {
	return session.session.Close()
}

type authenticatedTransport struct {
	next         http.RoundTripper
	gatewayToken string
	turnGrant    string
}

func (transport authenticatedTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	clone := request.Clone(request.Context())
	clone.Header = request.Header.Clone()
	clone.Header.Set("Authorization", "Bearer "+transport.gatewayToken)
	clone.Header.Set("X-Hunter-Turn-Grant", transport.turnGrant)
	return transport.next.RoundTrip(clone)
}

func FixedToolNames() []string {
	return []string{
		"get_artifact_example", "get_authoring_policy", "get_selected_context",
		"get_validation_result", "validate_ansible_draft", "validate_whiterabbit_draft",
	}
}

func verifyToolNames(names []string) error {
	got := slices.Clone(names)
	slices.Sort(got)
	if !slices.Equal(got, FixedToolNames()) {
		return ErrMCPRejected
	}
	return nil
}

func validCredential(value string) bool {
	return value != "" && len(value) <= 1024 && !strings.ContainsAny(value, "\x00\r\n\t ")
}
