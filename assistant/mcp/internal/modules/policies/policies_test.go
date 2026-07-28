package policies

import "testing"

func TestAuthoringPolicy(t *testing.T) {
	tl := Module{}.Tools()[0]
	if tl.Name != "get_authoring_policy" || tl.RequiresResource {
		t.Fatalf("policy tool must not require a resource: %+v", tl)
	}
	req, err := tl.Decode([]byte(`{"artifact_type":"whiterabbit_template"}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if req.Resource != nil {
		t.Fatal("policy decode must not set a resource")
	}
	call, _ := tl.BuildRequest(req)
	if call.Path != "/api/v1/assistant/machine/policies/whiterabbit_template" {
		t.Fatalf("path: %s", call.Path)
	}
	if _, err := tl.Decode([]byte(`{"artifact_type":"target"}`)); err == nil {
		t.Fatal("bad artifact_type accepted")
	}
	if err := tl.Validate([]byte(`{"correlation_id":"c","policy":{}}`)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"c","policy":{},"x":1}`)) == nil {
		t.Fatal("extra key accepted")
	}
}
