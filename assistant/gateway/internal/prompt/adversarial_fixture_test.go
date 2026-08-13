package prompt

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestAdversarialSelectedRecordFixturesStayUntrustedOrAreRejected(t *testing.T) {
	fixture, err := os.ReadFile("../../../testdata/adversarial/selected_records.json")
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Cases []struct {
			Name           string `json:"name"`
			Value          any    `json:"value"`
			Generator      string `json:"generator"`
			PromptExpected string `json:"prompt_expected"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(fixture, &document); err != nil {
		t.Fatal(err)
	}

	for _, testCase := range document.Cases {
		if testCase.PromptExpected == "" {
			continue
		}
		t.Run(testCase.Name, func(t *testing.T) {
			var value string
			switch testCase.Generator {
			case "oversized_string":
				value = strings.Repeat("x", MaxUserMessageBytes+1)
			case "malformed_utf8":
				value = string([]byte{'b', 'a', 'd', 0xff})
			default:
				var ok bool
				value, ok = testCase.Value.(string)
				if !ok {
					t.Fatal("prompt fixture value must be a string")
				}
			}
			built, buildErr := Build(value, []ContextReference{{Type: "target", ID: "abc", Label: value}})
			if testCase.PromptExpected == "invalid_untrusted_prompt" {
				if buildErr == nil {
					t.Fatal("accepted invalid untrusted fixture")
				}
				return
			}
			if buildErr != nil {
				t.Fatal(buildErr)
			}
			if strings.Contains(built.System, value) || !strings.Contains(built.UserContent, `"trust":"untrusted"`) {
				t.Fatal("untrusted fixture escaped its typed data block")
			}
		})
	}
}
