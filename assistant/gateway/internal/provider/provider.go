package provider

import (
	"context"
	"errors"
)

var ErrProviderUnavailable = errors.New("provider unavailable")

type Request struct {
	Model           string
	System          string
	UserContent     string
	MaxOutputTokens int
	ToolCallLimit   int
}

type ToolExecutor interface {
	Call(context.Context, string, []byte) ([]byte, error)
}

type Usage struct {
	InputTokens  int
	OutputTokens int
}

type Result struct {
	Envelope      Envelope
	Usage         Usage
	ToolCallCount int
}

type Adapter interface {
	Generate(context.Context, Request, ToolExecutor) (Result, error)
}

type Gateway struct {
	adapters map[string]Adapter
}

type HandleEvent struct {
	Result *Result
	Code   string
}

func NewGateway(openAI, anthropic Adapter) *Gateway {
	return &Gateway{adapters: map[string]Adapter{"openai": openAI, "anthropic": anthropic}}
}

func (gateway *Gateway) Handle(ctx context.Context, providerName string, request Request, executor ToolExecutor) HandleEvent {
	adapter, ok := gateway.adapters[providerName]
	if !ok || adapter == nil {
		return HandleEvent{Code: "provider_not_allowed"}
	}
	result, err := adapter.Generate(ctx, request, executor)
	if err != nil {
		return HandleEvent{Code: "provider_unavailable"}
	}
	return HandleEvent{Result: &result}
}
