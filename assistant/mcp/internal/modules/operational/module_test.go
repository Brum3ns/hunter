package operational

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"hunter.local/assistant/mcp/internal/catalog"
	"hunter.local/assistant/mcp/internal/tool"
)

func findTool(t *testing.T, name string) tool.Tool {
	t.Helper()
	for _, candidate := range (Module{}).Tools() {
		if candidate.Name == name {
			return candidate
		}
	}
	t.Fatalf("missing tool %s", name)
	return tool.Tool{}
}

func TestModuleToolsAreReviewedUniqueAndClosed(t *testing.T) {
	seen := map[string]struct{}{}
	for _, candidate := range (Module{}).Tools() {
		if _, duplicate := seen[candidate.Name]; duplicate {
			t.Fatalf("duplicate %s", candidate.Name)
		}
		seen[candidate.Name] = struct{}{}
		if _, reviewed := catalog.Lookup(candidate.Name); !reviewed {
			t.Fatalf("unreviewed tool %s", candidate.Name)
		}
		var input map[string]any
		if json.Unmarshal(candidate.InputSchema, &input) != nil || input["additionalProperties"] != false {
			t.Fatalf("input schema is not closed for %s", candidate.Name)
		}
	}
	if len(seen) != 34 {
		t.Fatalf("operational tool count = %d", len(seen))
	}
}

func TestSubmitJobBuildsOnlyReviewedMachineRoute(t *testing.T) {
	candidate := findTool(t, "submit_whiterabbit_job")
	request, err := candidate.Decode([]byte(`{
		"template":"httpx","queue_name":"test",
		"selections":[{"source":"targets","q":"tech:httpx","ids":[],"exclude_ids":[]}],
		"targets":["example.test"],"target_chunk":100,"delay":0
	}`))
	if err != nil {
		t.Fatal(err)
	}
	call, err := candidate.BuildRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if call.Method != "POST" || call.Path != "/api/v1/assistant/machine/control_center/jobs" {
		t.Fatalf("unexpected call %#v", call)
	}
	if strings.Contains(string(call.Body), "path") || strings.Contains(string(call.Body), "method") {
		t.Fatalf("generic request authority leaked into body: %s", call.Body)
	}
}

func TestOperationalInputsRejectUnknownAndSecretMaterial(t *testing.T) {
	cases := []struct {
		name string
		args string
	}{
		{"submit_whiterabbit_job", `{"template":"x","evil":true}`},
		{"resolve_job_targets", `{"selections":[{"source":"targets","evil":true}]}`},
		{"create_nonsecret_ansible_variable", `{"variable_set_id":1,"variable":{"name":"api_token","value_type":"string","value":"abcd"}}`},
		{"create_nonsecret_ansible_variable", `{"variable_set_id":1,"variable":{"name":"safe","value_type":"dictionary","value":{"password":"abcd"}}}`},
		{"launch_ansible_run_group", `{"playbook_id":1,"inventory_id":2,"overrides":[{"name":"token","value_type":"string","value":"abcd"}]}`},
		{"create_ansible_inventory", `{"inventory":{"name":"prod","yaml_content":"all:\n  vars:\n    password: abcd\n"}}`},
	}
	for _, test := range cases {
		if _, err := findTool(t, test.name).Decode([]byte(test.args)); err == nil {
			t.Errorf("%s accepted %s", test.name, test.args)
		}
	}
}

func TestInventoryEditBuildsVersionedClosedPatch(t *testing.T) {
	candidate := findTool(t, "edit_ansible_inventory")
	request, err := candidate.Decode([]byte(`{"id":7,"expected_lock_version":2,"changes":{"description":"updated"}}`))
	if err != nil {
		t.Fatal(err)
	}
	call, err := candidate.BuildRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/inventories/7" || call.Method != "PATCH" {
		t.Fatalf("unexpected call %#v", call)
	}
	if strings.Contains(string(call.Body), `"id"`) || !strings.Contains(string(call.Body), `"expected_lock_version":2`) {
		t.Fatalf("unexpected body %s", call.Body)
	}
}

func TestCredentialProjectionValidatorRejectsAuthenticationMaterial(t *testing.T) {
	candidate := findTool(t, "get_ansible_credential_metadata")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","credential":{` +
		`"id":1,"name":"prod","auth_type":"password","username":"deploy","public_key_fingerprint":null,` +
		`"private_key_configured":false,"ssh_password_configured":true,"private_key_passphrase_configured":false,` +
		`"become_password_configured":false,"last_used_at":null,"created_at":"2026-08-19T00:00:00Z","updated_at":"2026-08-19T00:00:00Z"}}`
	if err := candidate.Validate([]byte(good)); err != nil {
		t.Fatalf("safe credential rejected: %v", err)
	}
	bad := strings.Replace(good, `"ssh_password_configured":true`, `"ssh_password_configured":true,"ssh_password":"secret"`, 1)
	if candidate.Validate([]byte(bad)) == nil {
		t.Fatal("credential secret field accepted")
	}
}

func TestExportValidatorRequiresBrowserReferenceAndNeverArchiveBytes(t *testing.T) {
	candidate := findTool(t, "export_ansible_playbooks")
	receipt := `{"receipt_id":"3b241101-e2bb-4255-8caf-4136c566a963","tool":"export_ansible_playbooks",` +
		`"status":"exported","target":{"type":"assistant_export_artifact","id":"1"},"human_user_id":1,"turn_id":null,` +
		`"idempotency_digest":"` + strings.Repeat("a", 64) + `","replayed":false,"occurred_at":"2026-08-19T00:00:00Z",` +
		`"artifact":{"kind":"ansible_playbooks","filename":"playbooks.zip","byte_count":100,"expires_at":"2026-08-19T00:15:00Z",` +
		`"browser_download_reference":"/assistant/exports/signed-id"}}`
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","receipt":` + receipt + `}`
	if err := candidate.Validate([]byte(good)); err != nil {
		t.Fatalf("safe export rejected: %v", err)
	}
	bad := strings.Replace(good, `"byte_count":100`, `"byte_count":100,"archive":"UEsDB"`, 1)
	if candidate.Validate([]byte(bad)) == nil {
		t.Fatal("archive bytes accepted")
	}
}

func TestOperationalModuleContainsNoDeletionOrGenericProxy(t *testing.T) {
	for _, candidate := range (Module{}).Tools() {
		for _, word := range []string{"delete", "destroy", "purge", "request", "shell", "filesystem"} {
			if slices.Contains(strings.Split(candidate.Name, "_"), word) {
				t.Fatalf("prohibited tool name %s", candidate.Name)
			}
		}
	}
}
