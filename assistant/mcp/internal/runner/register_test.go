package runner

import (
	"context"
	"testing"

	"hunter.local/assistant/mcp/internal/transport"
)

func TestPublicErrorMapping(t *testing.T) {
	cases := map[error]string{
		ErrUnknownTool:           "unknown_tool",
		ErrInvalidInput:          "invalid_tool_input",
		ErrResourceDenied:        "scope_not_granted",
		ErrScopeDenied:           "scope_not_granted",
		ErrToolDenied:            "scope_not_granted",
		ErrGrantExpired:          "turn_grant_expired",
		ErrCallBudgetExhausted:   "turn_call_budget_exhausted",
		ErrResponseRejected:      "tool_response_rejected",
		context.Canceled:         "tool_call_cancelled",
		context.DeadlineExceeded: "tool_call_cancelled",
	}
	for err, want := range cases {
		if got := PublicError(err); got != want {
			t.Errorf("PublicError(%v)=%q want %q", err, got, want)
		}
	}
}

func TestPublicErrorIncludesOnlyBoundedStableValidationCodes(t *testing.T) {
	err := &transport.HunterError{
		Code:  "validation_failed",
		Codes: []string{"whiterabbit_command_not_allowed", "artifact_secret_material_not_allowed"},
	}
	if got, want := PublicError(err), "validation_failed: whiterabbit_command_not_allowed, artifact_secret_material_not_allowed"; got != want {
		t.Fatalf("PublicError = %q, want %q", got, want)
	}
}

func TestWrapResult(t *testing.T) {
	if _, _, ok := wrapResult([]byte(`not json`)); ok {
		t.Fatal("expected rejection of non-object payload")
	}
	wrapped, encoded, ok := wrapResult([]byte(`{"a":1}`))
	if !ok {
		t.Fatal("expected object payload to wrap")
	}
	if _, hasResult := wrapped["result"]; !hasResult {
		t.Fatal("wrapped payload missing result envelope")
	}
	if string(encoded) != `{"result":{"a":1}}` {
		t.Fatalf("encoded=%s", encoded)
	}
}
