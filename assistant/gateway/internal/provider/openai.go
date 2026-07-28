package provider

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"

	openai "github.com/openai/openai-go/v3"
	openaioption "github.com/openai/openai-go/v3/option"
	"github.com/openai/openai-go/v3/responses"
)

const openAIBaseURL = "https://api.openai.com/v1"

type OpenAIAdapter struct {
	client openai.Client
}

func NewOpenAIAdapter(apiKey string, client *http.Client) *OpenAIAdapter {
	return newOpenAIAdapter(apiKey, openAIBaseURL, client)
}

func newOpenAIAdapter(apiKey, baseURL string, httpClient *http.Client) *OpenAIAdapter {
	client := openai.NewClient(
		openaioption.WithAPIKey(apiKey),
		openaioption.WithBaseURL(baseURL),
		openaioption.WithHTTPClient(httpClient),
		openaioption.WithMaxRetries(0),
	)
	return &OpenAIAdapter{client: client}
}

func (adapter *OpenAIAdapter) Generate(ctx context.Context, request Request, executor ToolExecutor) (Result, error) {
	if err := validateRequest(request); err != nil {
		return Result{}, err
	}
	format := responses.ResponseFormatTextConfigParamOfJSONSchema("hunter_assistant_result", strictSchemaMap(OutputSchema()))
	format.OfJSONSchema.Strict = openai.Bool(true)
	input := responses.ResponseInputParam{
		responses.ResponseInputItemParamOfMessage(request.UserContent, responses.EasyInputMessageRoleUser),
	}
	params := responses.ResponseNewParams{
		Background:        openai.Bool(false),
		Instructions:      openai.String(request.System),
		MaxOutputTokens:   openai.Int(int64(request.MaxOutputTokens)),
		MaxToolCalls:      openai.Int(int64(request.ToolCallLimit)),
		ParallelToolCalls: openai.Bool(false),
		Store:             openai.Bool(false),
		Include:           []responses.ResponseIncludable{responses.ResponseIncludableReasoningEncryptedContent},
		Input:             responses.ResponseNewParamsInputUnion{OfInputItemList: input},
		Model:             responsesModel(request.Model),
		Text:              responses.ResponseTextConfigParam{Format: format},
		Tools:             openAITools(),
		Truncation:        responses.ResponseNewParamsTruncationDisabled,
	}
	evidence := make(map[string]ValidationEvidence)
	usage := Usage{}
	toolCalls := 0
	for round := 0; round <= request.ToolCallLimit; round++ {
		params.Input = responses.ResponseNewParamsInputUnion{OfInputItemList: input}
		response, err := adapter.client.Responses.New(ctx, params)
		if err != nil {
			return Result{}, ErrProviderUnavailable
		}
		usage.InputTokens += int(response.Usage.InputTokens)
		usage.OutputTokens += int(response.Usage.OutputTokens)
		if response.Status != responses.ResponseStatusCompleted {
			return Result{}, errors.New("incomplete provider response")
		}

		roundCalls := 0
		for _, item := range response.Output {
			switch item.Type {
			case "function_call":
				call := item.AsFunctionCall()
				if executor == nil || call.CallID == "" || len(call.CallID) > 255 || !slices.Contains(FixedToolNames(), call.Name) || len(call.Arguments) > 64<<10 || !json.Valid([]byte(call.Arguments)) || toolCalls >= request.ToolCallLimit {
					return Result{}, errors.New("provider tool call rejected")
				}
				output, err := executor.Call(ctx, call.Name, []byte(call.Arguments))
				if err != nil || len(output) == 0 || len(output) > 64<<10 || !json.Valid(output) {
					return Result{}, errors.New("MCP tool call failed")
				}
				input = append(input,
					responses.ResponseInputItemParamOfFunctionCall(call.Arguments, call.CallID, call.Name),
					responses.ResponseInputItemParamOfFunctionCallOutput(call.CallID, string(output)),
				)
				evidence[call.CallID] = ValidationEvidence{Tool: call.Name, Result: append([]byte(nil), output...)}
				toolCalls++
				roundCalls++
			case "reasoning":
				reasoning := item.AsReasoning().ToParam()
				input = append(input, responses.ResponseInputItemUnionParam{OfReasoning: &reasoning})
			case "message":
				// A final message is parsed after every item has proved free of
				// hosted/unknown calls. Intermediate prose is not trusted as output.
			default:
				return Result{}, errors.New("provider returned a hosted or unknown tool")
			}
		}
		if roundCalls > 0 {
			continue
		}
		envelope, err := ParseEnvelope([]byte(response.OutputText()), evidence)
		if err != nil {
			return Result{}, err
		}
		return Result{Envelope: envelope, Usage: usage, ToolCallCount: toolCalls}, nil
	}
	return Result{}, errors.New("provider tool call limit exceeded")
}

func openAITools() []responses.ToolUnionParam {
	definitions := fixedTools()
	tools := make([]responses.ToolUnionParam, 0, len(definitions))
	for _, definition := range definitions {
		tool := responses.ToolParamOfFunction(definition.Name, strictSchemaMap(definition.Schema), true)
		tool.OfFunction.Description = openai.String(definition.Description)
		tools = append(tools, tool)
	}
	return tools
}

func responsesModel(value string) openai.ChatModel {
	return openai.ChatModel(value)
}

func validateRequest(request Request) error {
	if request.Model == "" || request.System == "" || request.UserContent == "" || request.MaxOutputTokens < 1 || request.MaxOutputTokens > 8192 || request.ToolCallLimit < 1 || request.ToolCallLimit > 8 {
		return errors.New("invalid provider request")
	}
	return nil
}
