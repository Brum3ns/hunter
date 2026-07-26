package provider

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
)

func TestOpenAIRequestDisablesStorageAndHostedTools(t *testing.T) {
	requests := make(chan map[string]any, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/responses" || r.Header.Get("Authorization") != "Bearer test-openai-key" {
			t.Fatalf("path=%q authorization=%q", r.URL.Path, r.Header.Get("Authorization"))
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		requests <- body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{
          "id":"resp_1","object":"response","created_at":1,"model":"gpt-5",
          "status":"completed","output":[{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"kind\":\"assistant_message\",\"body\":\"hello\",\"artifact_type\":null,\"name\":null,\"content\":null,\"validation_call_id\":null}","annotations":[]}]}],
          "usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}
        }`))
	}))
	defer server.Close()

	adapter := newOpenAIAdapter("test-openai-key", server.URL+"/v1", server.Client())
	result, err := adapter.Generate(context.Background(), Request{
		Model: "gpt-5", System: "system", UserContent: `{"trust":"untrusted"}`,
		MaxOutputTokens: 512, ToolCallLimit: 8,
	}, noToolExecutor{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Envelope.Body != "hello" {
		t.Fatalf("result=%+v", result)
	}

	request := <-requests
	if request["store"] != false || request["background"] != false || request["parallel_tool_calls"] != false {
		t.Fatalf("unsafe flags: %+v", request)
	}
	if _, present := request["previous_response_id"]; present {
		t.Fatal("provider-side conversation state enabled")
	}
	tools, ok := request["tools"].([]any)
	if !ok || !slices.Equal(toolNamesFromJSON(tools), FixedToolNames()) {
		t.Fatalf("tools=%v", tools)
	}
	for _, raw := range tools {
		tool := raw.(map[string]any)
		if tool["type"] != "function" || tool["strict"] != true {
			t.Fatalf("non-strict function tool: %+v", tool)
		}
	}
	for _, forbidden := range []string{"web_search", "computer_use", "file_search", "code_interpreter", "mcp", "background"} {
		for _, raw := range tools {
			if raw.(map[string]any)["type"] == forbidden {
				t.Fatalf("hosted tool %q enabled", forbidden)
			}
		}
	}
	format := request["text"].(map[string]any)["format"].(map[string]any)
	if format["type"] != "json_schema" || format["strict"] != true {
		t.Fatalf("format=%+v", format)
	}
}

func TestOpenAIToolCallRunsThroughExecutorBeforeDraft(t *testing.T) {
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
          "id":"resp_1","object":"response","created_at":1,"model":"gpt-5","status":"completed",
          "output":[{"id":"fc_1","type":"function_call","call_id":"call-1","name":"validate_ansible_draft","arguments":"{\"draft\":{\"name\":\"Check\",\"source\":\"---\\n- hosts: all\"}}","status":"completed"}],
          "usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14}
        }`))
			return
		case 2:
			_, _ = w.Write([]byte(`{
          "id":"resp_2","object":"response","created_at":2,"model":"gpt-5","status":"completed",
          "output":[{"id":"fc_2","type":"function_call","call_id":"call-2","name":"get_validation_result","arguments":"{\"id\":\"123e4567-e89b-42d3-a456-426614174001\"}","status":"completed"}],
          "usage":{"input_tokens":15,"output_tokens":4,"total_tokens":19}
        }`))
			return
		}
		_, _ = w.Write([]byte(`{
          "id":"resp_3","object":"response","created_at":3,"model":"gpt-5","status":"completed",
          "output":[{"id":"msg_1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"{\"kind\":\"draft\",\"body\":null,\"artifact_type\":\"ansible_playbook\",\"name\":\"Check\",\"content\":\"---\\n- hosts: all\",\"validation_call_id\":\"call-2\"}","annotations":[]}]}],
          "usage":{"input_tokens":20,"output_tokens":8,"total_tokens":28}
        }`))
	}))
	defer server.Close()

	executor := &recordingExecutor{}
	adapter := newOpenAIAdapter("test-openai-key", server.URL+"/v1", server.Client())
	result, err := adapter.Generate(context.Background(), Request{
		Model: "gpt-5", System: "system", UserContent: `{"trust":"untrusted"}`,
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
	input := third["input"].([]any)
	types := make([]string, 0, len(input))
	for _, item := range input {
		if itemType, ok := item.(map[string]any)["type"].(string); ok {
			types = append(types, itemType)
		}
	}
	if !slices.Contains(types, "function_call") || !slices.Contains(types, "function_call_output") {
		t.Fatalf("continuation types=%v", types)
	}
}

func toolNamesFromJSON(tools []any) []string {
	names := make([]string, 0, len(tools))
	for _, raw := range tools {
		names = append(names, raw.(map[string]any)["name"].(string))
	}
	slices.Sort(names)
	return names
}

type recordingExecutor struct {
	names []string
	args  []byte
}

func (executor *recordingExecutor) Call(_ context.Context, name string, args []byte) ([]byte, error) {
	executor.names = append(executor.names, name)
	executor.args = append([]byte(nil), args...)
	status := "pending"
	valid := false
	if name == "get_validation_result" {
		status = "valid"
		valid = true
	}
	return []byte(fmt.Sprintf(`{"result":{"correlation_id":"123e4567-e89b-42d3-a456-426614174000","validation":{"id":"123e4567-e89b-42d3-a456-426614174001","artifact_type":"ansible_playbook","status":%q,"valid":%t,"version":"ansible-syntax-v1","normalized":{"source":"---\n- hosts: all"},"content_digest":"28ad997a9b69fd01669580750ec10562a10d52d132990bc9de0dacf4171c5f65","details":{"codes":[],"messages":[]}}}}`, status, valid)), nil
}
