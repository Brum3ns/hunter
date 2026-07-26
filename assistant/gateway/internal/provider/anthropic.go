package provider

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
	anthropicoption "github.com/anthropics/anthropic-sdk-go/option"
)

const anthropicBaseURL = "https://api.anthropic.com"

type AnthropicAdapter struct {
	client anthropic.Client
}

func NewAnthropicAdapter(apiKey string, client *http.Client) *AnthropicAdapter {
	return newAnthropicAdapter(apiKey, anthropicBaseURL, client)
}

func newAnthropicAdapter(apiKey, baseURL string, httpClient *http.Client) *AnthropicAdapter {
	client := anthropic.NewClient(
		anthropicoption.WithAPIKey(apiKey),
		anthropicoption.WithBaseURL(baseURL),
		anthropicoption.WithHTTPClient(httpClient),
		anthropicoption.WithMaxRetries(0),
	)
	return &AnthropicAdapter{client: client}
}

func (adapter *AnthropicAdapter) Generate(ctx context.Context, request Request, executor ToolExecutor) (Result, error) {
	if err := validateRequest(request); err != nil {
		return Result{}, err
	}
	messages := []anthropic.MessageParam{
		anthropic.NewUserMessage(anthropic.NewTextBlock(request.UserContent)),
	}
	params := anthropic.MessageNewParams{
		MaxTokens: int64(request.MaxOutputTokens),
		Messages:  messages,
		Model:     anthropic.Model(request.Model),
		System:    []anthropic.TextBlockParam{{Text: request.System}},
		ToolChoice: anthropic.ToolChoiceUnionParam{
			OfAuto: &anthropic.ToolChoiceAutoParam{DisableParallelToolUse: anthropic.Bool(true)},
		},
		Tools: anthropicTools(),
		OutputConfig: anthropic.OutputConfigParam{
			Format: anthropic.JSONOutputFormatParam{Schema: OutputSchema()},
		},
	}
	evidence := make(map[string]ValidationEvidence)
	usage := Usage{}
	toolCalls := 0
	for round := 0; round <= request.ToolCallLimit; round++ {
		params.Messages = messages
		message, err := adapter.client.Messages.New(ctx, params)
		if err != nil {
			return Result{}, ErrProviderUnavailable
		}
		usage.InputTokens += int(message.Usage.InputTokens)
		usage.OutputTokens += int(message.Usage.OutputTokens)

		switch message.StopReason {
		case anthropic.StopReasonToolUse:
			assistantBlocks := make([]anthropic.ContentBlockParamUnion, 0, len(message.Content))
			toolResults := make([]anthropic.ContentBlockParamUnion, 0, 1)
			for _, block := range message.Content {
				if block.Type != "tool_use" {
					return Result{}, errors.New("unexpected provider content during tool call")
				}
				call := block.AsToolUse()
				if executor == nil || call.ID == "" || len(call.ID) > 255 || !slices.Contains(FixedToolNames(), call.Name) || len(call.Input) > 64<<10 || !json.Valid(call.Input) || toolCalls >= request.ToolCallLimit {
					return Result{}, errors.New("provider tool call rejected")
				}
				output, err := executor.Call(ctx, call.Name, call.Input)
				if err != nil || len(output) == 0 || len(output) > 64<<10 || !json.Valid(output) {
					return Result{}, errors.New("MCP tool call failed")
				}
				callParam := call.ToParam()
				assistantBlocks = append(assistantBlocks, anthropic.ContentBlockParamUnion{OfToolUse: &callParam})
				toolResults = append(toolResults, anthropic.NewToolResultBlock(call.ID, string(output), false))
				evidence[call.ID] = ValidationEvidence{Tool: call.Name, Result: append([]byte(nil), output...)}
				toolCalls++
			}
			if len(toolResults) == 0 {
				return Result{}, errors.New("empty provider tool turn")
			}
			messages = append(messages, anthropic.NewAssistantMessage(assistantBlocks...), anthropic.NewUserMessage(toolResults...))
		case anthropic.StopReasonEndTurn:
			var output strings.Builder
			for _, block := range message.Content {
				if block.Type != "text" {
					return Result{}, errors.New("unexpected provider content")
				}
				output.WriteString(block.Text)
			}
			envelope, err := ParseEnvelope([]byte(output.String()), evidence)
			if err != nil {
				return Result{}, err
			}
			return Result{Envelope: envelope, Usage: usage, ToolCallCount: toolCalls}, nil
		default:
			return Result{}, errors.New("incomplete provider response")
		}
	}
	return Result{}, errors.New("provider tool call limit exceeded")
}

func anthropicTools() []anthropic.ToolUnionParam {
	definitions := fixedTools()
	tools := make([]anthropic.ToolUnionParam, 0, len(definitions))
	for _, definition := range definitions {
		properties, _ := definition.Schema["properties"].(map[string]any)
		required, _ := definition.Schema["required"].([]string)
		tools = append(tools, anthropic.ToolUnionParam{OfTool: &anthropic.ToolParam{
			InputSchema: anthropic.ToolInputSchemaParam{
				Properties:  properties,
				Required:    required,
				ExtraFields: map[string]any{"additionalProperties": false},
			},
			Name: definition.Name, Description: anthropic.String(definition.Description),
			Strict: anthropic.Bool(true), Type: anthropic.ToolTypeCustom,
			AllowedCallers: []string{"direct"},
		}})
	}
	return tools
}
