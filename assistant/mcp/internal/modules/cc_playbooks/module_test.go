package cc_playbooks

import (
	"testing"

	"hunter.local/assistant/mcp/internal/tool"
)

func find(t *testing.T, name string) tool.Tool {
	t.Helper()
	for _, tl := range (Module{}).Tools() {
		if tl.Name == name {
			return tl
		}
	}
	t.Fatalf("missing tool %s", name)
	return tool.Tool{}
}

func TestListPlaybooksScope(t *testing.T) {
	tl := find(t, "list_playbooks")
	if tl.Scope != "control_center_ansible" || tl.RequiresResource {
		t.Fatalf("scope/resource wrong: %+v", tl)
	}
}

func TestListPlaybooksBuildsQuery(t *testing.T) {
	tl := find(t, "list_playbooks")
	req, err := tl.Decode([]byte(`{"limit":10}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/playbooks?limit=10" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestListPlaybooksRejectsUnknownField(t *testing.T) {
	tl := find(t, "list_playbooks")
	if _, err := tl.Decode([]byte(`{"evil":1}`)); err == nil {
		t.Fatal("unknown field accepted")
	}
}

func TestGetPlaybookBuildsPathAndValidatesID(t *testing.T) {
	tl := find(t, "get_playbook")
	req, err := tl.Decode([]byte(`{"id":"42"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/control_center/ansible/playbooks/42" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"id":"not-an-int"}`)); err == nil {
		t.Fatal("non-integer id accepted")
	}
}

func TestListPlaybooksOutputValidation(t *testing.T) {
	tl := find(t, "list_playbooks")
	good := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"name":"Baseline","description":"d","checksum":"abc","updated_at":"2026-01-01"}]}`
	if err := tl.Validate([]byte(good)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	bad := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","count":1,"page":1,"limit":50,` +
		`"items":[{"id":1,"name":"Baseline","description":"d","checksum":"abc","updated_at":"2026-01-01","yaml_content":"x"}]}`
	if tl.Validate([]byte(bad)) == nil {
		t.Fatal("accepted invalid output (yaml_content leaked in summary)")
	}
}

func TestGetPlaybookOutputValidation(t *testing.T) {
	tl := find(t, "get_playbook")
	full := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","playbook":{` +
		`"id":1,"name":"Baseline","description":"d","checksum":"abc","updated_at":"2026-01-01",` +
		`"yaml_content":"---","variable_set_ids":[],"created_at":"2026-01-01"}}`
	if err := tl.Validate([]byte(full)); err != nil {
		t.Fatalf("valid full output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","playbook":{"id":1}}`)) == nil {
		t.Fatal("partial playbook accepted")
	}
}
