package provider

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
)

func TestAnthropicRequestUsesOnlyStrictClientToolsAndStructuredOutput(t *testing.T) {
	requests := make(chan map[string]any, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/messages" || r.Header.Get("X-Api-Key") != "test-anthropic-key" {
			t.Fatalf("path=%q key=%q", r.URL.Path, r.Header.Get("X-Api-Key"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		requests <- body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
          "id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5",
          "content":[{"type":"text","text":"{\"kind\":\"assistant_message\",\"body\":\"hello\",\"artifact_type\":null,\"name\":null,\"content\":null,\"validation_call_id\":null}"}],
          "stop_reason":"end_turn","stop_sequence":null,
          "usage":{"input_tokens":10,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}
        }`))
	}))
	defer server.Close()

	adapter := newAnthropicAdapter("test-anthropic-key", server.URL, server.Client())
	result, err := adapter.Generate(context.Background(), Request{
		Model: "claude-sonnet-5", System: "system", UserContent: `{"trust":"untrusted"}`,
		MaxOutputTokens: 512, ToolCallLimit: 8,
	}, noToolExecutor{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Envelope.Body != "hello" {
		t.Fatalf("result=%+v", result)
	}

	request := <-requests
	tools, ok := request["tools"].([]any)
	if !ok || !slices.Equal(toolNamesFromJSON(tools), FixedToolNames()) {
		t.Fatalf("tools=%v", tools)
	}
	for _, raw := range tools {
		tool := raw.(map[string]any)
		if tool["strict"] != true || tool["type"] == "web_search_20250305" || tool["type"] == "code_execution_20250522" {
			t.Fatalf("unsafe tool: %+v", tool)
		}
		if _, cached := tool["cache_control"]; cached {
			t.Fatal("prompt caching enabled")
		}
	}
	format := request["output_config"].(map[string]any)["format"].(map[string]any)
	if format["type"] != "json_schema" {
		t.Fatalf("format=%+v", format)
	}
}

func TestAnthropicToolCallRunsThroughExecutorBeforeDraft(t *testing.T) {
	var calls atomic.Int32
	requests := make(chan map[string]any, 3)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		requests <- body
		w.Header().Set("Content-Type", "application/json")
		switch calls.Add(1) {
		case 1:
			_, _ = w.Write([]byte(`{
          "id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5",
          "content":[{"type":"tool_use","id":"call-1","name":"validate_ansible_draft","input":{"draft":{"name":"Check","source":"---\n- hosts: all"}}}],
          "stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":4}
        }`))
			return
		case 2:
			_, _ = w.Write([]byte(`{
          "id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-5",
          "content":[{"type":"tool_use","id":"call-2","name":"get_validation_result","input":{"id":"123e4567-e89b-42d3-a456-426614174001"}}],
          "stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":15,"output_tokens":4}
        }`))
			return
		}
		_, _ = w.Write([]byte(`{
          "id":"msg_3","type":"message","role":"assistant","model":"claude-sonnet-5",
          "content":[{"type":"text","text":"{\"kind\":\"draft\",\"body\":null,\"artifact_type\":\"ansible_playbook\",\"name\":\"Check\",\"content\":\"---\\n- hosts: all\",\"validation_call_id\":\"call-2\"}"}],
          "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":20,"output_tokens":8}
        }`))
	}))
	defer server.Close()

	executor := &recordingExecutor{}
	adapter := newAnthropicAdapter("test-anthropic-key", server.URL, server.Client())
	result, err := adapter.Generate(context.Background(), Request{
		Model: "claude-sonnet-5", System: "system", UserContent: `{"trust":"untrusted"}`,
		MaxOutputTokens: 512, ToolCallLimit: 2,
	}, executor)
	if err != nil {
		t.Fatal(err)
	}
	if result.Envelope.Kind != "draft" || result.ToolCallCount != 2 || !slices.Equal(executor.names, []string{"validate_ansible_draft", "get_validation_result"}) {
		t.Fatalf("result=%+v executor=%+v", result, executor)
	}
	<-requests
	<-requests
	third := <-requests
	messages := third["messages"].([]any)
	if len(messages) != 5 || messages[3].(map[string]any)["role"] != "assistant" || messages[4].(map[string]any)["role"] != "user" {
		t.Fatalf("continuation messages=%+v", messages)
	}
}

type noToolExecutor struct{}

func (noToolExecutor) Call(context.Context, string, []byte) ([]byte, error) {
	return nil, context.Canceled
}
