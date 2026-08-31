package capabilities

import (
	"strings"
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

func TestCapabilityToolValidatesExactTokenOnlyLimits(t *testing.T) {
	definition := (Module{}).Tools()[0]
	valid := `{
		"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962",
		"authorization_mode":"token_only",
		"catalog_version":1,
		"limits":{
			"calls_per_turn":null,"calls_hard_ceiling":null,
			"result_bytes_per_call":1048576,"result_bytes_per_turn":null,
			"effects_per_turn":null,"effects_per_hour":120,
			"launches_per_turn":null,"launches_per_hour":60
		},
		"tools":[{
			"name":"list_targets","module":"targets","effect":"read",
			"scope":"targets_read","gate":"targets","rate_profile":"read","idempotency":"none"
		}]
	}`
	if err := definition.Validate([]byte(valid)); err != nil {
		t.Fatalf("valid response rejected: %v", err)
	}

	for name, invalid := range map[string]string{
		"unknown top field": strings.Replace(valid, `"tools":[`, `"secret":"x","tools":[`, 1),
		"wrong mode":        strings.Replace(valid, `"token_only"`, `"turn_grant"`, 1),
		"missing mode":      strings.Replace(valid, `"authorization_mode":"token_only",`, ``, 1),
		"fake turn limit":   strings.Replace(valid, `"calls_per_turn":null`, `"calls_per_turn":64`, 1),
		"null per call":     strings.Replace(valid, `"result_bytes_per_call":1048576`, `"result_bytes_per_call":null`, 1),
		"large per call":    strings.Replace(valid, `"result_bytes_per_call":1048576`, `"result_bytes_per_call":1048577`, 1),
		"null hourly":       strings.Replace(valid, `"effects_per_hour":120`, `"effects_per_hour":null`, 1),
		"large effects":     strings.Replace(valid, `"effects_per_hour":120`, `"effects_per_hour":241`, 1),
		"large launches":    strings.Replace(valid, `"launches_per_hour":60`, `"launches_per_hour":121`, 1),
		"missing limit":     strings.Replace(valid, `"launches_per_turn":null,`, ``, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if err := definition.Validate([]byte(invalid)); err == nil {
				t.Fatalf("invalid response accepted: %s", invalid)
			}
		})
	}
}
