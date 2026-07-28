package context

import "testing"

func TestGetSelectedContextTool(t *testing.T) {
	tools := Module{}.Tools()
	if len(tools) != 1 || tools[0].Name != "get_selected_context" || !tools[0].RequiresResource {
		t.Fatalf("unexpected tool: %+v", tools)
	}
	tl := tools[0]
	req, err := tl.Decode([]byte(`{"type":"target","id":"host-1"}`))
	if err != nil || req.Resource == nil || req.Resource.Type != "target" {
		t.Fatalf("decode: %+v err=%v", req, err)
	}
	call, err := tl.BuildRequest(req)
	if err != nil || call.Method != "GET" || call.Path != "/api/v1/assistant/machine/contexts/target/host-1" {
		t.Fatalf("build: %+v err=%v", call, err)
	}
	if err := tl.Validate([]byte(`{"correlation_id":"c","context":{}}`)); err != nil {
		t.Fatalf("valid output rejected: %v", err)
	}
	if tl.Validate([]byte(`{"correlation_id":"c","context":{},"extra":1}`)) == nil {
		t.Fatal("extra key accepted")
	}
	if tl.Validate([]byte(`{"correlation_id":"c"}`)) == nil {
		t.Fatal("missing key accepted")
	}
	if _, err := tl.Decode([]byte(`{"type":"bogus","id":"x"}`)); err == nil {
		t.Fatal("bad type accepted")
	}
}
