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
			Format: anthropic.JSONOutputFormatParam{Schema: strictSchemaMap(OutputSchema())},
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
			toolResults := make([]anthropic.ContentBlockParamUnion, 0, 1)
			for _, block := range message.Content {
				switch block.Type {
				case "tool_use":
					call := block.AsToolUse()
					if executor == nil || call.ID == "" || len(call.ID) > 255 || !slices.Contains(FixedToolNames(), call.Name) || len(call.Input) > 64<<10 || !json.Valid(call.Input) || toolCalls >= request.ToolCallLimit {
						return Result{}, errors.New("provider tool call rejected")
					}
					output, err := executor.Call(ctx, call.Name, call.Input)
					if err != nil || len(output) == 0 || len(output) > 64<<10 || !json.Valid(output) {
						// A tool call can legitimately fail — e.g. the model
						// speculatively reads an example, context, or validation the
						// turn was never granted. Return that failure TO THE MODEL as
						// an error result so it recovers and still answers, instead of
						// aborting the whole turn. Aborting turned every such turn into
						// provider_unavailable. No evidence is recorded for a failed
						// call, so a draft can never cite one.
						toolResults = append(toolResults, anthropic.NewToolResultBlock(call.ID,
							`{"error":"This resource was not granted for this turn. Do not retry this tool. Answer the user directly from your own knowledge with an assistant_message."}`, true))
						toolCalls++
						continue
					}
					toolResults = append(toolResults, anthropic.NewToolResultBlock(call.ID, string(output), false))
					evidence[call.ID] = ValidationEvidence{Tool: call.Name, Result: append([]byte(nil), output...)}
					toolCalls++
				case "thinking", "redacted_thinking", "text":
					// Adaptive thinking is on by default for Sonnet 5, so a tool-use
					// turn arrives as [thinking, (text?), tool_use] — the thinking and
					// any text preamble are NOT an error. They are echoed back verbatim
					// via message.ToParam() below, which the API requires: a follow-up
					// turn that drops the thinking block preceding a tool_use is rejected.
				default:
					return Result{}, errors.New("unexpected provider content during tool call")
				}
			}
			if len(toolResults) == 0 {
				return Result{}, errors.New("empty provider tool turn")
			}
			// Echo the whole assistant message (thinking + tool_use) unchanged, then
			// the tool results. NewAssistantMessage with only the tool_use blocks
			// would strip the thinking block and the next request would 400.
			messages = append(messages, message.ToParam(), anthropic.NewUserMessage(toolResults...))
		case anthropic.StopReasonEndTurn:
			var output strings.Builder
			for _, block := range message.Content {
				switch block.Type {
				case "text":
					output.WriteString(block.Text)
				case "thinking", "redacted_thinking":
					// Thinking blocks carry no envelope content; skip them.
				default:
					return Result{}, errors.New("unexpected provider content")
				}
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
		schema := strictSchemaMap(definition.Schema)
		properties, _ := schema["properties"].(map[string]any)
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
