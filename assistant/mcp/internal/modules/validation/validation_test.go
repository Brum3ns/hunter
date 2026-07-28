package validation

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

func TestValidationToolsPresent(t *testing.T) {
	for _, want := range []string{"get_validation_result", "validate_whiterabbit_draft", "validate_ansible_draft"} {
		find(t, want)
	}
}

func TestWhiterabbitDraftRoundTrip(t *testing.T) {
	wr := find(t, "validate_whiterabbit_draft")
	body := `{"draft":{"name":"n","commands":[{"command":"curl","args":["-s"]}]}}`
	req, err := wr.Decode([]byte(body))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, err := wr.BuildRequest(req)
	if err != nil || call.Method != "POST" || call.Path != "/api/v1/assistant/machine/validations/whiterabbit_template" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if len(call.Body) == 0 {
		t.Fatal("expected marshaled body")
	}
	if _, err := wr.Decode([]byte(`{"draft":{"name":"","commands":[]}}`)); err == nil {
		t.Fatal("empty draft accepted")
	}
}

func TestAnsibleDraftRoundTrip(t *testing.T) {
	an := find(t, "validate_ansible_draft")
	req, err := an.Decode([]byte(`{"draft":{"name":"n","source":"---\n- hosts: all"}}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := an.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/validations/ansible_playbook" {
		t.Fatalf("path: %s", call.Path)
	}
}

func TestValidationResultRoundTrip(t *testing.T) {
	vr := find(t, "get_validation_result")
	req, err := vr.Decode([]byte(`{"id":"abc-123"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := vr.BuildRequest(req)
	if call.Method != "GET" || call.Path != "/api/v1/assistant/machine/validation_results/abc-123" {
		t.Fatalf("build: %+v", call)
	}
	if _, err := vr.Decode([]byte(`{"id":"bad id"}`)); err == nil {
		t.Fatal("bad id accepted")
	}
}

func TestValidateOutputRejects(t *testing.T) {
	wr := find(t, "validate_whiterabbit_draft")
	cases := map[string]string{
		"extraTopKey":       `{"correlation_id":"c","validation":{},"x":1}`,
		"missingValidation": `{"correlation_id":"c"}`,
		"badCorrelation":    `{"correlation_id":"not-a-uuid","validation":{}}`,
	}
	for name, in := range cases {
		if wr.Validate([]byte(in)) == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestValidateOutputAcceptsValidWhiterabbit(t *testing.T) {
	wr := find(t, "validate_whiterabbit_draft")
	// valid whiterabbit result: status valid, no codes, normalized draft present, no id.
	payload := `{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","validation":{` +
		`"id":null,"artifact_type":"whiterabbit_template","status":"valid","valid":true,"version":"v1",` +
		`"normalized":{"name":"n","commands":[{"command":"curl","args":["-s"]}]},"content_digest":"` +
		`0000000000000000000000000000000000000000000000000000000000000000",` +
		`"details":{"codes":[],"messages":[]}}}`
	if err := wr.Validate([]byte(payload)); err != nil {
		t.Fatalf("valid whiterabbit output rejected: %v", err)
	}
}
