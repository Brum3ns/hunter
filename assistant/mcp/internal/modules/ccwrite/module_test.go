package ccwrite

import (
	"encoding/json"
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func find(t *testing.T, tools []tool.Tool, name string) tool.Tool {
	t.Helper()
	for _, x := range tools {
		if x.Name == name {
			return x
		}
	}
	t.Fatalf("tool %q not built", name)
	return tool.Tool{}
}

func TestCreateWhiterabbitTemplateScope(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	if tl.Scope != "control_center_templates_write" {
		t.Fatalf("scope = %q", tl.Scope)
	}
}

func TestCreateAnsiblePlaybookScope(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	if tl.Scope != "control_center_ansible_write" {
		t.Fatalf("scope = %q", tl.Scope)
	}
}

func TestCreateWhiterabbitTemplateBuildsRequest(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	req, err := tl.Decode([]byte(`{"template":{"name":"n","kind":"cmdscript","commands":[{"command":"curl","args":["-s"]}]}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if call.Method != "POST" {
		t.Fatalf("method = %q", call.Method)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/templates" {
		t.Fatalf("path = %q", call.Path)
	}
	if len(call.Body) == 0 {
		t.Fatal("empty body")
	}
}

func TestCreateWhiterabbitTemplateRejectsUnknownField(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	args := []byte(`{"template":{"name":"n","kind":"cmdscript","commands":[{"command":"curl"}]},"evil":1}`)
	if _, err := tl.Decode(args); err == nil {
		t.Fatal("unknown top-level field accepted")
	}
	args = []byte(`{"template":{"name":"n","kind":"cmdscript","commands":[{"command":"curl","evil":1}]}}`)
	if _, err := tl.Decode(args); err == nil {
		t.Fatal("unknown command field accepted")
	}
}

func TestCreateWhiterabbitTemplateRejectsBadKind(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	args := []byte(`{"template":{"name":"n","kind":"bogus","commands":[{"command":"curl"}]}}`)
	if _, err := tl.Decode(args); err == nil {
		t.Fatal("invalid kind accepted")
	}
}

func TestCreateWhiterabbitTemplateValidatesOutput(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{"id":1,"name":"n"}}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{"id":1,"name":"n","extra":1}}`
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra artifact key accepted")
	}
	extraRoot := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","template":{"id":1,"name":"n"},"extra":1}`
	if tl.Validate([]byte(extraRoot)) == nil {
		t.Fatal("extra root key accepted")
	}
}

func TestCreateAnsiblePlaybookBuildsRequest(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	req, err := tl.Decode([]byte(`{"playbook":{"name":"n","source":"---\n- hosts: all\n"}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if call.Method != "POST" {
		t.Fatalf("method = %q", call.Method)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/playbooks" {
		t.Fatalf("path = %q", call.Path)
	}
	if len(call.Body) == 0 {
		t.Fatal("empty body")
	}
}

func TestCreateAnsiblePlaybookRejectsUnknownField(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	args := []byte(`{"playbook":{"name":"n","source":"x"},"evil":1}`)
	if _, err := tl.Decode(args); err == nil {
		t.Fatal("unknown field accepted")
	}
	args = []byte(`{"playbook":{"name":"n","source":"x","evil":1}}`)
	if _, err := tl.Decode(args); err == nil {
		t.Fatal("unknown playbook field accepted")
	}
}

func TestCreateAnsiblePlaybookValidatesOutput(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","playbook":{"id":1,"name":"n"}}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","playbook":{"id":1,"name":"n","extra":1}}`
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra artifact key accepted")
	}
}

func TestModuleReturnsBothTools(t *testing.T) {
	tools := Module{}.Tools()
	if len(tools) != 2 {
		t.Fatalf("expected 2 tools, got %d", len(tools))
	}
	var raw map[string]json.RawMessage
	for _, tl := range tools {
		if err := json.Unmarshal(tl.InputSchema, &raw); err != nil {
			t.Fatalf("%s: input schema not valid JSON: %v", tl.Name, err)
		}
	}
}
