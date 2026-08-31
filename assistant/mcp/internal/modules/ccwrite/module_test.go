package ccwrite

import (
	"encoding/json"
	"strings"
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

func receipt(toolName, targetType string) string {
	return `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","receipt":{` +
		`"receipt_id":"3b241101-e2bb-4255-8caf-4136c566a963","tool":"` + toolName + `","status":"created",` +
		`"target":{"type":"` + targetType + `","id":"1"},"human_user_id":1,"turn_id":null,` +
		`"idempotency_digest":"` + strings.Repeat("a", 64) + `","replayed":false,"occurred_at":"2026-08-19T00:00:00Z"}}`
}

func TestCreateWhiterabbitTemplateScope(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	if tl.Scope != "control_center_templates_write" || !tl.WriteScope {
		t.Fatalf("scope = %q write=%v", tl.Scope, tl.WriteScope)
	}
}

func TestCreateAnsiblePlaybookScope(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	if tl.Scope != "control_center_ansible_write" || !tl.WriteScope {
		t.Fatalf("scope = %q write=%v", tl.Scope, tl.WriteScope)
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

func TestCreateWhiterabbitTemplateNormalizesMissingCommandFields(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_whiterabbit_template")
	req, err := tl.Decode([]byte(`{"template":{"name":"httpx proof","kind":"cmdscript","commands":[{"command":"httpx"}]}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if !strings.Contains(string(call.Body), `"args":[]`) || !strings.Contains(string(call.Body), `"operator":""`) {
		t.Fatalf("command defaults missing from body: %s", call.Body)
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
	good := receipt("create_whiterabbit_template", "whiterabbit_template")
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := strings.Replace(good, `"replayed":false`, `"replayed":false,"extra":1`, 1)
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra artifact key accepted")
	}
	extraRoot := strings.TrimSuffix(good, "}") + `,"extra":1}`
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

func TestMaximumPlaybookSourceFitsInsideTheEncodedRequestBudget(t *testing.T) {
	tl := find(t, Module{}.Tools(), "create_ansible_playbook")
	encoded, err := json.Marshal(map[string]any{
		"playbook": map[string]any{"name": "max-source", "source": strings.Repeat("<", 65_536)},
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(encoded) <= 256<<10 {
		t.Fatalf("fixture does not cross the old envelope cap: %d", len(encoded))
	}
	req, err := tl.Decode(encoded)
	if err != nil {
		t.Fatalf("decode exact source maximum: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build exact source maximum: %v", err)
	}
	if len(call.Body) > maxRequestBytes {
		t.Fatalf("encoded body %d exceeds budget %d", len(call.Body), maxRequestBytes)
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
	good := receipt("create_ansible_playbook", "ansible_playbook")
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid rejected: %v", err)
	}
	extra := strings.Replace(good, `"replayed":false`, `"replayed":false,"extra":1`, 1)
	if tl.Validate([]byte(extra)) == nil {
		t.Fatal("extra artifact key accepted")
	}
}

func TestModuleReturnsBothTools(t *testing.T) {
	tools := Module{}.Tools()
	if len(tools) != 4 {
		t.Fatalf("expected 4 tools, got %d", len(tools))
	}
	var raw map[string]json.RawMessage
	for _, tl := range tools {
		if err := json.Unmarshal(tl.InputSchema, &raw); err != nil {
			t.Fatalf("%s: input schema not valid JSON: %v", tl.Name, err)
		}
	}
}

func TestEditWhiterabbitTemplateBuildsClosedPatch(t *testing.T) {
	tl := find(t, Module{}.Tools(), "edit_whiterabbit_template")
	if tl.Scope != "control_center_templates_edit" || !tl.WriteScope {
		t.Fatalf("scope = %q write=%v", tl.Scope, tl.WriteScope)
	}
	req, err := tl.Decode([]byte(`{"id":7,"expected_lock_version":2,"changes":{"commands":[{"command":"httpx","args":["-l","targets.txt"]}]}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if call.Method != "PATCH" || call.Path != "/api/v1/assistant/machine/control_center/templates/7" {
		t.Fatalf("call = %#v", call)
	}
	if !strings.Contains(string(call.Body), `"expected_lock_version":2`) || !strings.Contains(string(call.Body), `"operator":""`) {
		t.Fatalf("unexpected body: %s", call.Body)
	}
}

func TestEditAnsiblePlaybookBuildsClosedPatch(t *testing.T) {
	tl := find(t, Module{}.Tools(), "edit_ansible_playbook")
	if tl.Scope != "control_center_ansible_edit" || !tl.WriteScope {
		t.Fatalf("scope = %q write=%v", tl.Scope, tl.WriteScope)
	}
	req, err := tl.Decode([]byte(`{"id":9,"expected_lock_version":0,"changes":{"description":"safe","variable_set_ids":[3,4]}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	if call.Method != "PATCH" || call.Path != "/api/v1/assistant/machine/control_center/ansible/playbooks/9" {
		t.Fatalf("call = %#v", call)
	}
}

func TestEditToolsRejectInvalidAuthorityAndChanges(t *testing.T) {
	cases := []struct {
		tool string
		args string
	}{
		{"edit_whiterabbit_template", `{"id":0,"expected_lock_version":0,"changes":{"description":"x"}}`},
		{"edit_whiterabbit_template", `{"id":1,"expected_lock_version":-1,"changes":{"description":"x"}}`},
		{"edit_whiterabbit_template", `{"id":1,"expected_lock_version":0,"changes":{}}`},
		{"edit_whiterabbit_template", `{"id":1,"expected_lock_version":0,"changes":{"evil":true}}`},
		{"edit_ansible_playbook", `{"id":1,"expected_lock_version":0,"changes":{}}`},
		{"edit_ansible_playbook", `{"id":1,"expected_lock_version":0,"changes":{"variable_set_ids":[2,2]}}`},
	}
	for _, tc := range cases {
		if _, err := find(t, Module{}.Tools(), tc.tool).Decode([]byte(tc.args)); err == nil {
			t.Errorf("%s accepted %s", tc.tool, tc.args)
		}
	}
}

func TestAuthoringToolsAdvertiseExactOutputSchema(t *testing.T) {
	for _, tl := range (Module{}).Tools() {
		var schema map[string]any
		if err := json.Unmarshal(tl.OutputSchema, &schema); err != nil {
			t.Fatalf("%s output schema: %v", tl.Name, err)
		}
		encoded, _ := json.Marshal(schema)
		for _, required := range []string{`"additionalProperties":false`, `"correlation_id"`, `"receipt_id"`} {
			if !strings.Contains(string(encoded), required) {
				t.Errorf("%s output schema lacks %s: %s", tl.Name, required, encoded)
			}
		}
	}
}
