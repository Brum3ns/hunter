package runner

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"hunter.local/assistant/mcp/internal/auth"
)

// Register binds every registry tool to the MCP server, routing calls through
// the runner pipeline and shaping success/error into the SDK's result type.
func Register(server *mcp.Server, r *Runner) {
	for _, definition := range r.registry.Tools() {
		definition := definition
		server.AddTool(&mcp.Tool{
			Name:         definition.Name,
			Description:  definition.Description,
			InputSchema:  definition.InputSchema,
			OutputSchema: definition.OutputSchema,
		}, func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			payload, err := r.Dispatch(ctx, auth.GrantFromContext(ctx), definition.Name, request.Params.Arguments)
			if err != nil {
				return &mcp.CallToolResult{
					Content: []mcp.Content{&mcp.TextContent{Text: PublicError(err)}},
					IsError: true,
				}, nil
			}
			wrapped, encoded, ok := wrapResult(payload)
			if !ok {
				return &mcp.CallToolResult{
					Content: []mcp.Content{&mcp.TextContent{Text: "tool_response_rejected"}},
					IsError: true,
				}, nil
			}
			return &mcp.CallToolResult{
				Content:           []mcp.Content{&mcp.TextContent{Text: string(encoded)}},
				StructuredContent: wrapped,
			}, nil
		})
	}
}

// wrapResult verifies the payload is a JSON object and envelopes it as {result:…}.
func wrapResult(payload []byte) (map[string]any, []byte, bool) {
	var result map[string]any
	if err := json.Unmarshal(payload, &result); err != nil {
		return nil, nil, false
	}
	wrapped := map[string]any{"result": result}
	encoded, err := json.Marshal(wrapped)
	if err != nil {
		return nil, nil, false
	}
	return wrapped, encoded, true
}

// PublicError maps an internal runner error to a stable, non-revealing token.
func PublicError(err error) string {
	if code, ok := stableHunterCode(err); ok {
		return code
	}
	switch {
	case errors.Is(err, ErrUnknownTool):
		return "unknown_tool"
	case errors.Is(err, ErrInvalidInput):
		return "invalid_tool_input"
	case errors.Is(err, ErrResourceDenied):
		return "scope_not_granted"
	case errors.Is(err, ErrScopeDenied):
		return "scope_not_granted"
	case errors.Is(err, ErrCallBudgetExhausted):
		return "turn_call_budget_exhausted"
	case errors.Is(err, ErrGrantExpired):
		return "turn_grant_expired"
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "tool_call_cancelled"
	case errors.Is(err, ErrToolDenied):
		return "scope_not_granted"
	default:
		return "tool_response_rejected"
	}
}
