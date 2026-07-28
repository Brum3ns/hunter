package tools

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestAdversarialToolInputFixtures(t *testing.T) {
	fixture, err := os.ReadFile("../../../testdata/adversarial/tool_inputs.json")
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Cases []struct {
			Name      string          `json:"name"`
			Tool      string          `json:"tool"`
			Arguments json.RawMessage `json:"arguments"`
			Generator string          `json:"generator"`
			Expected  string          `json:"expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(fixture, &document); err != nil {
		t.Fatal(err)
	}

	for _, testCase := range document.Cases {
		t.Run(testCase.Name, func(t *testing.T) {
			arguments := testCase.Arguments
			switch testCase.Generator {
			case "oversized_source":
				arguments, _ = json.Marshal(map[string]any{
					"draft": map[string]any{"name": "x", "source": strings.Repeat("x", 65_537)},
				})
			case "deep_json":
				arguments = []byte(`{"type":"target","id":"abc","nested":` +
					strings.Repeat(`{"value":`, 80) + `null` + strings.Repeat(`}`, 80) + `}`)
			case "malformed_utf8":
				arguments = append([]byte(`{"draft":{"name":"x","source":"`), 0xff)
				arguments = append(arguments, []byte(`"}}`)...)
			}

			_, _, inputErr := decodeInput(testCase.Tool, arguments)
			if actual := publicError(inputErr); actual != testCase.Expected {
				t.Fatalf("expected %q, got %q (%v)", testCase.Expected, actual, inputErr)
			}
		})
	}
}
