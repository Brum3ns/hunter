package tools

import (
	"context"
	"encoding/json"
	"slices"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"hunter.local/assistant/mcp/internal/auth"
	"hunter.local/assistant/mcp/internal/hunter"
)

type Definition struct {
	Name         string
	Description  string
	InputSchema  json.RawMessage
	OutputSchema json.RawMessage
}

type Catalog []Definition

func NewCatalog(_ hunter.Client) Catalog {
	resourceSchema := schema(`{
    "type":"object",
    "additionalProperties":false,
    "required":["type","id"],
    "properties":{
      "type":{"type":"string","enum":["program","target","cve","vulnerability","whiterabbit_template","ansible_playbook"]},
      "id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}
    }
  }`)
	artifactSchema := schema(`{
    "type":"object",
    "additionalProperties":false,
    "required":["artifact_type"],
    "properties":{"artifact_type":{"type":"string","enum":["whiterabbit_template","ansible_playbook"]}}
  }`)
	validationResultSchema := schema(`{
    "type":"object",
    "additionalProperties":false,
    "required":["id"],
    "properties":{"id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}}
  }`)
	whiterabbitSchema := schema(`{
    "type":"object",
    "additionalProperties":false,
    "required":["draft"],
    "properties":{"draft":{
      "type":"object","additionalProperties":false,"required":["name","commands"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "kind":{"type":"string","maxLength":40},
        "description":{"type":"string","maxLength":4000},
        "commands":{"type":"array","maxItems":50,"items":{
          "type":"object","additionalProperties":false,"required":["command","args"],
          "properties":{
            "command":{"type":"string","minLength":1,"maxLength":255},
            "args":{"type":"array","maxItems":200,"items":{"type":"string","maxLength":4096}},
            "operator":{"type":"string","maxLength":4}
          }
        }}
      }
    }}
  }`)
	ansibleSchema := schema(`{
    "type":"object",
    "additionalProperties":false,
    "required":["draft"],
    "properties":{"draft":{
      "type":"object","additionalProperties":false,"required":["name","source"],
      "properties":{
        "name":{"type":"string","minLength":1,"maxLength":200},
        "source":{"type":"string","minLength":1,"maxLength":65536}
      }
    }}
  }`)
	outputSchema := schema(`{
    "type":"object","additionalProperties":false,"required":["result"],
    "properties":{"result":{"type":"object"}}
  }`)

	return Catalog{
		{Name: "get_artifact_example", Description: "Return one explicitly granted sanitized artifact example.", InputSchema: resourceSchema, OutputSchema: outputSchema},
		{Name: "get_authoring_policy", Description: "Return the non-secret authoring policy for one artifact type.", InputSchema: artifactSchema, OutputSchema: outputSchema},
		{Name: "get_selected_context", Description: "Return one explicitly granted sanitized Hunter context record.", InputSchema: resourceSchema, OutputSchema: outputSchema},
		{Name: "get_validation_result", Description: "Return a validation result bound to this turn.", InputSchema: validationResultSchema, OutputSchema: outputSchema},
		{Name: "validate_ansible_draft", Description: "Validate an Ansible draft without saving or executing it.", InputSchema: ansibleSchema, OutputSchema: outputSchema},
		{Name: "validate_whiterabbit_draft", Description: "Validate a Whiterabbit draft without saving or sending it.", InputSchema: whiterabbitSchema, OutputSchema: outputSchema},
	}
}

func ToolNames(catalog Catalog) []string {
	names := make([]string, 0, len(catalog))
	for _, definition := range catalog {
		names = append(names, definition.Name)
	}
	slices.Sort(names)
	return names
}

func Register(server *mcp.Server, handler *Handler) {
	for _, definition := range NewCatalog(handler.client) {
		definition := definition
		server.AddTool(&mcp.Tool{
			Name:         definition.Name,
			Description:  definition.Description,
			InputSchema:  definition.InputSchema,
			OutputSchema: definition.OutputSchema,
		}, func(ctx context.Context, request *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
			payload, err := handler.Call(ctx, auth.GrantFromContext(ctx), definition.Name, request.Params.Arguments)
			if err != nil {
				return &mcp.CallToolResult{
					Content: []mcp.Content{&mcp.TextContent{Text: publicError(err)}},
					IsError: true,
				}, nil
			}
			var result map[string]any
			if err := json.Unmarshal(payload, &result); err != nil {
				return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "tool_response_rejected"}}, IsError: true}, nil
			}
			wrapped := map[string]any{"result": result}
			encoded, _ := json.Marshal(wrapped)
			return &mcp.CallToolResult{
				Content:           []mcp.Content{&mcp.TextContent{Text: string(encoded)}},
				StructuredContent: wrapped,
			}, nil
		})
	}
}

func schema(value string) json.RawMessage {
	return json.RawMessage(value)
}
