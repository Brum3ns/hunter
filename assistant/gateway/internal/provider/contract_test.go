package provider

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
)

type fakeAdapter struct {
	result Result
	err    error
	calls  int
}

func (adapter *fakeAdapter) Generate(context.Context, Request, ToolExecutor) (Result, error) {
	adapter.calls++
	return adapter.result, adapter.err
}

func TestProviderNeverFallsBack(t *testing.T) {
	openAI := &fakeAdapter{err: errors.New("provider down")}
	anthropic := &fakeAdapter{result: Result{Envelope: Envelope{Kind: "assistant_message", Body: "must not run"}}}
	gateway := NewGateway(openAI, anthropic)

	event := gateway.Handle(context.Background(), "openai", Request{}, nil)
	if event.Code != "provider_unavailable" {
		t.Fatalf("event=%+v", event)
	}
	if openAI.calls != 1 || anthropic.calls != 0 {
		t.Fatalf("calls openai=%d anthropic=%d", openAI.calls, anthropic.calls)
	}
}

func TestEnvelopeIsClosedAndDraftRequiresMatchingValidationEvidence(t *testing.T) {
	if _, err := ParseEnvelope([]byte(`{"kind":"assistant_message","body":"hello","artifact_type":null,"name":null,"content":null,"validation_call_id":null,"extra":true}`), nil); err == nil {
		t.Fatal("accepted an unknown field")
	}
	if _, err := ParseEnvelope([]byte("{\"kind\":\"assistant_message\",\"body\":\"bad\\u0000body\",\"artifact_type\":null,\"name\":null,\"content\":null,\"validation_call_id\":null}"), nil); err == nil {
		t.Fatal("accepted a control character")
	}

	draft := []byte(`{"kind":"draft","body":null,"artifact_type":"ansible_playbook","name":"Check","content":"---\n- hosts: all","validation_call_id":"call-1"}`)
	if _, err := ParseEnvelope(draft, nil); err == nil {
		t.Fatal("accepted model-asserted validation without tool evidence")
	}
	evidence := map[string]ValidationEvidence{
		"call-1": {Tool: "get_validation_result", Result: []byte(`{"result":{"correlation_id":"123e4567-e89b-42d3-a456-426614174000","validation":{"id":"123e4567-e89b-42d3-a456-426614174001","artifact_type":"ansible_playbook","status":"valid","valid":true,"version":"ansible-syntax-v1","normalized":{"source":"---\n- hosts: all"},"content_digest":"28ad997a9b69fd01669580750ec10562a10d52d132990bc9de0dacf4171c5f65","details":{"codes":[],"messages":[]}}}}`)},
	}
	parsed, err := ParseEnvelope(draft, evidence)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.ValidationStatus != "valid" || parsed.ValidationVersion != "ansible-syntax-v1" {
		t.Fatalf("parsed=%+v", parsed)
	}
	tampered := []byte(`{"kind":"draft","body":null,"artifact_type":"ansible_playbook","name":"Check","content":"---\n- hosts: changed","validation_call_id":"call-1"}`)
	if _, err := ParseEnvelope(tampered, evidence); err == nil {
		t.Fatal("accepted content that does not match validation evidence")
	}
}

func TestEnvelopeRequiresEveryBranchField(t *testing.T) {
	if _, err := ParseEnvelope([]byte(`{"kind":"assistant_message","body":"hello"}`), nil); err == nil {
		t.Fatal("assistant envelope with omitted draft fields was accepted")
	}
}

func TestStrictSchemasRequireEveryObjectProperty(t *testing.T) {
	if err := validateStrictObjectSchema(OutputSchema(), true); err != nil {
		t.Fatalf("output schema is not strict-compatible: %v", err)
	}
	for _, tool := range fixedTools() {
		if err := validateStrictObjectSchema(tool.Schema, true); err != nil {
			t.Fatalf("tool %s schema is not strict-compatible: %v", tool.Name, err)
		}
	}
}

func validateStrictObjectSchema(schema map[string]any, root bool) error {
	if root {
		if schema["type"] != "object" {
			return fmt.Errorf("root type=%v", schema["type"])
		}
		if _, present := schema["oneOf"]; present {
			return fmt.Errorf("root oneOf is unsupported")
		}
		if _, present := schema["anyOf"]; present {
			return fmt.Errorf("root anyOf is unsupported")
		}
	}
	if schema["type"] == "object" {
		if schema["additionalProperties"] != false {
			return fmt.Errorf("object permits additional properties")
		}
		properties, _ := schema["properties"].(map[string]any)
		required, _ := schema["required"].([]string)
		for name := range properties {
			if !slices.Contains(required, name) {
				return fmt.Errorf("property %q is optional", name)
			}
		}
		for _, value := range properties {
			if child, ok := value.(map[string]any); ok {
				if err := validateStrictObjectSchema(child, false); err != nil {
					return err
				}
			}
		}
	}
	if items, ok := schema["items"].(map[string]any); ok {
		if err := validateStrictObjectSchema(items, false); err != nil {
			return err
		}
	}
	for _, keyword := range []string{"anyOf", "oneOf"} {
		if branches, ok := schema[keyword].([]any); ok {
			for _, branch := range branches {
				if child, ok := branch.(map[string]any); ok {
					if err := validateStrictObjectSchema(child, false); err != nil {
						return err
					}
				}
			}
		}
	}
	return nil
}
