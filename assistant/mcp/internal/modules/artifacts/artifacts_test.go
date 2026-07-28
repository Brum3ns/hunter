package artifacts

import "testing"

func TestArtifactExampleRestrictsType(t *testing.T) {
	tl := Module{}.Tools()[0]
	if tl.Name != "get_artifact_example" || !tl.RequiresResource {
		t.Fatalf("unexpected tool: %+v", tl)
	}
	if _, err := tl.Decode([]byte(`{"type":"target","id":"x"}`)); err == nil {
		t.Fatal("non-artifact type accepted")
	}
	req, err := tl.Decode([]byte(`{"type":"ansible_playbook","id":"pb-1"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/artifacts/ansible_playbook/pb-1" {
		t.Fatalf("path: %s", call.Path)
	}
	if err := tl.Validate([]byte(`{"correlation_id":"c","artifact":{}}`)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"c","artifact":{},"x":1}`)) == nil {
		t.Fatal("extra key accepted")
	}
}
