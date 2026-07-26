package provider

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

func TestAdversarialProviderEnvelopeFixturesFailClosed(t *testing.T) {
	fixture, err := os.ReadFile("../../../testdata/adversarial/provider_outputs.json")
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Cases []struct {
			Name      string `json:"name"`
			Payload   string `json:"payload"`
			Generator string `json:"generator"`
			Expected  string `json:"expected"`
		} `json:"adversarial_envelopes"`
	}
	if err := json.Unmarshal(fixture, &document); err != nil {
		t.Fatal(err)
	}

	for _, testCase := range document.Cases {
		t.Run(testCase.Name, func(t *testing.T) {
			payload := []byte(testCase.Payload)
			switch testCase.Generator {
			case "oversized_body":
				body, _ := json.Marshal(strings.Repeat("x", (64<<10)+1))
				payload = []byte(`{"kind":"assistant_message","body":` + string(body) +
					`,"artifact_type":null,"name":null,"content":null,"validation_call_id":null}`)
			case "malformed_utf8":
				payload = append([]byte(`{"kind":"assistant_message","body":"`), 0xff)
				payload = append(payload, []byte(`","artifact_type":null,"name":null,"content":null,"validation_call_id":null}`)...)
			}

			_, parseErr := ParseEnvelope(payload, nil)
			actual := "accepted"
			if errors.Is(parseErr, ErrInvalidEnvelope) {
				actual = "invalid_provider_envelope"
			}
			if actual != testCase.Expected {
				t.Fatalf("expected %q, got %q (%v)", testCase.Expected, actual, parseErr)
			}
		})
	}
}
