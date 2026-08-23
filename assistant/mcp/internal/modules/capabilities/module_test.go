package capabilities

import (
	"testing"
)

func TestCapabilityToolBuildsOnlyTheDedicatedMachineRequest(t *testing.T) {
	definition := (Module{}).Tools()[0]
	if definition.Name != "list_hunter_capabilities" || definition.Scope != "hunter_capabilities_read" {
		t.Fatalf("unexpected definition: %+v", definition)
	}
	request, err := definition.Decode([]byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	call, err := definition.BuildRequest(request)
	if err != nil || call.Method != "GET" || call.Path != "/api/v1/assistant/machine/capabilities" || call.Body != nil {
		t.Fatalf("unexpected call: %+v %v", call, err)
	}
	if _, err := definition.Decode([]byte(`{"method":"DELETE"}`)); err == nil {
		t.Fatal("unknown/generic input accepted")
	}
}

func TestCapabilityToolValidatesClosedSafeOutput(t *testing.T) {
	definition := (Module{}).Tools()[0]
	valid := []byte(`{
		"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962",
		"catalog_version":1,
		"limits":{
			"calls_per_turn":64,"calls_hard_ceiling":128,
			"result_bytes_per_call":1048576,"result_bytes_per_turn":16777216,
			"effects_per_turn":32,"effects_per_hour":120,
			"launches_per_turn":16,"launches_per_hour":60
		},
		"tools":[{
			"name":"list_targets","module":"targets","effect":"read",
			"scope":"targets_read","gate":"targets","rate_profile":"read","idempotency":"none"
		}]
	}`)
	if err := definition.Validate(valid); err != nil {
		t.Fatalf("valid response rejected: %v", err)
	}
	for _, invalid := range [][]byte{
		[]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","catalog_version":1,"limits":{},"tools":[],"secret":"x"}`),
		[]byte(`{"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962","catalog_version":1,"limits":{"calls_per_turn":129,"calls_hard_ceiling":128,"result_bytes_per_call":1048576,"result_bytes_per_turn":16777216,"effects_per_turn":32,"effects_per_hour":120,"launches_per_turn":16,"launches_per_hour":60},"tools":[]}`),
	} {
		if err := definition.Validate(invalid); err == nil {
			t.Fatalf("invalid response accepted: %s", invalid)
		}
	}
}
