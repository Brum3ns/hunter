package tools

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"hunter.local/assistant/mcp/internal/hunter"
)

type fakeHunterClient struct {
	grant       hunter.Grant
	postPayload []byte
}

func (client fakeHunterClient) Introspect(context.Context, string) (hunter.Grant, error) {
	if client.grant.Tools != nil {
		return client.grant, nil
	}
	return hunter.Grant{
		Tools:          ToolNames(NewCatalog(fakeHunterClient{})),
		CallsRemaining: 8,
		BytesRemaining: 64 * 1024,
		ExpiresAt:      time.Now().Add(time.Minute),
	}, nil
}

func TestHandlerDoubleChecksToolAndResourceScope(t *testing.T) {
	client := fakeHunterClient{grant: hunter.Grant{
		Tools:          []string{"get_selected_context"},
		Resources:      []hunter.Resource{{Type: "target", ID: "abc"}},
		CallsRemaining: 1,
		BytesRemaining: 1024,
		ExpiresAt:      time.Now().Add(time.Minute),
	}}
	handler := NewHandler(client, nil)

	if _, err := handler.Call(context.Background(), "turn-grant", "get_selected_context", []byte(`{"type":"target","id":"other"}`)); !errors.Is(err, ErrResourceDenied) {
		t.Fatalf("resource got %v", err)
	}
	if _, err := handler.Call(context.Background(), "turn-grant", "get_artifact_example", []byte(`{"type":"whiterabbit_template","id":"1"}`)); !errors.Is(err, ErrToolDenied) {
		t.Fatalf("tool got %v", err)
	}
}
func (fakeHunterClient) Get(context.Context, string, string, string, string) ([]byte, error) {
	return []byte(`{"ok":true}`), nil
}

func (client fakeHunterClient) Post(context.Context, string, string, any) ([]byte, error) {
	if client.postPayload != nil {
		return client.postPayload, nil
	}
	return []byte(`{"valid":true}`), nil
}

func TestCatalogIsExactAndReadOnly(t *testing.T) {
	got := ToolNames(NewCatalog(fakeHunterClient{}))
	want := []string{"get_artifact_example", "get_authoring_policy", "get_selected_context", "get_validation_result", "validate_ansible_draft", "validate_whiterabbit_draft"}
	if !slices.Equal(want, got) {
		t.Fatalf("want %v, got %v", want, got)
	}
	for _, forbidden := range []string{"http", "shell", "search", "write", "execute", "filesystem"} {
		if slices.Contains(got, forbidden) {
			t.Fatalf("forbidden tool %q", forbidden)
		}
	}
}

func TestClosedInputRejectsUnknownPropertiesAndURLs(t *testing.T) {
	cases := []string{
		`{"type":"target","id":"abc","extra":true}`,
		`{"type":"target","id":"https://example.test"}`,
		`{"type":"target","id":"abc","url":"https://example.test"}`,
	}
	for _, input := range cases {
		if _, err := DecodeExactResource([]byte(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}

func TestValidationHandlerAcceptsOnlyTheClosedRailsResponseEnvelope(t *testing.T) {
	payload := []byte(`{
		"correlation_id":"123e4567-e89b-42d3-a456-426614174001",
		"validation":{
			"id":"123e4567-e89b-42d3-a456-426614174000",
			"artifact_type":"ansible_playbook",
			"status":"pending",
			"valid":false,
			"version":"ansible-syntax-v1",
			"normalized":{"name":"check","source":"---\n- hosts: workers\n  tasks: []\n"},
			"content_digest":"5ca2400a20f89741c23b5a1b0c3e43561fbf4b2ac8d420899077998761cae8b3",
			"details":{"codes":[],"messages":[]}
		}
	}`)
	handler := NewHandler(fakeHunterClient{postPayload: payload}, nil)
	result, err := handler.Call(context.Background(), "turn-grant", "validate_ansible_draft", []byte(`{
		"draft":{"name":"check","source":"---\n- hosts: workers\n  tasks: []\n"}
	}`))
	if err != nil || !slices.Equal(result, payload) {
		t.Fatalf("result=%s err=%v", result, err)
	}

	rejected := NewHandler(fakeHunterClient{postPayload: []byte(`{
		"correlation_id":"123e4567-e89b-42d3-a456-426614174001",
		"validation":{
			"id":null,"artifact_type":"ansible_playbook","status":"invalid","valid":false,
			"version":"ansible-static-v1","normalized":null,"content_digest":null,
			"details":{"codes":["ansible_schema_invalid"],"messages":["Draft rejected."],"raw_api":true}
		}
	}`)}, nil)
	if _, err := rejected.Call(context.Background(), "turn-grant", "validate_ansible_draft", []byte(`{"draft":{"name":"check","source":"---\n- hosts: workers\n  tasks: []\n"}}`)); !errors.Is(err, ErrResponseRejected) {
		t.Fatalf("unexpected response error: %v", err)
	}
}
