package runner

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	artifacts "hunter.local/assistant/mcp/internal/modules/artifacts"
	contextmod "hunter.local/assistant/mcp/internal/modules/context"
	policies "hunter.local/assistant/mcp/internal/modules/policies"
	validation "hunter.local/assistant/mcp/internal/modules/validation"
)

// decodeOutcome mirrors the runner's pre-dispatch input handling: an unknown
// tool maps to unknown_tool, a decode failure to invalid_tool_input.
func decodeOutcome(reg *Registry, name string, args []byte) string {
	t, ok := reg.Lookup(name)
	if !ok {
		return PublicError(ErrUnknownTool)
	}
	if _, err := t.Decode(args); err != nil {
		return PublicError(ErrInvalidInput)
	}
	return ""
}

// TestAdversarialToolInputFixtures keeps the guarantee that dangerous tool names
// (shell, list_all_targets, execute_playbook, …) resolve to unknown_tool and that
// hostile inputs to real tools are rejected as invalid_tool_input.
func TestAdversarialToolInputFixtures(t *testing.T) {
	reg := NewRegistry()
	reg.Add(contextmod.Module{}, artifacts.Module{}, policies.Module{}, validation.Module{})

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

			if actual := decodeOutcome(reg, testCase.Tool, arguments); actual != testCase.Expected {
				t.Fatalf("expected %q, got %q", testCase.Expected, actual)
			}
		})
	}
}
