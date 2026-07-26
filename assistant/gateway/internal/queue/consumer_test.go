package queue

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestDecodeTurnJobIsClosedAndBounded(t *testing.T) {
	payload := validTurnJob(t)
	job, err := DecodeTurnJob(payload, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if job.ProviderProfile.Provider != "openai" || job.TurnGrant != strings.Repeat("g", 32) {
		t.Fatalf("job=%+v", job)
	}

	var expanded map[string]any
	if err := json.Unmarshal(payload, &expanded); err != nil {
		t.Fatal(err)
	}
	expanded["unexpected"] = true
	unsafe, _ := json.Marshal(expanded)
	if _, err := DecodeTurnJob(unsafe, time.Now()); err == nil {
		t.Fatal("accepted an unknown queue field")
	}
}

func TestDecodeTurnJobRejectsExpiredAndMismatchedProfiles(t *testing.T) {
	var payload map[string]any
	if err := json.Unmarshal(validTurnJob(t), &payload); err != nil {
		t.Fatal(err)
	}
	payload["expires_at"] = time.Now().Add(-time.Second).UTC().Format(time.RFC3339)
	expired, _ := json.Marshal(payload)
	if _, err := DecodeTurnJob(expired, time.Now()); err == nil {
		t.Fatal("accepted an expired job")
	}

	profile := payload["provider_profile"].(map[string]any)
	payload["expires_at"] = time.Now().Add(time.Minute).UTC().Format(time.RFC3339)
	profile["secret_ref"] = "anthropic_primary"
	mismatch, _ := json.Marshal(payload)
	if _, err := DecodeTurnJob(mismatch, time.Now()); err == nil {
		t.Fatal("accepted a mismatched provider credential")
	}
}

func validTurnJob(t *testing.T) []byte {
	t.Helper()
	payload := map[string]any{
		"schema_version": 1,
		"correlation_id": "b3a7e1a2-34ab-4aa1-8fc0-5f507a33d1af",
		"turn_id":        1, "conversation_id": 2, "user_id": 3,
		"provider_profile": map[string]any{
			"profile_id": 4, "catalog_slug": "openai_primary", "provider": "openai",
			"model": "gpt-5", "secret_ref": "openai_primary", "input_limit": 4096,
			"output_limit": 2048, "tool_call_limit": 8, "retention_posture": "standard",
			"reviewed_at": time.Now().Add(-time.Hour).UTC().Format(time.RFC3339),
		},
		"user_message": "Draft a safe check",
		"context_references": []any{
			map[string]any{"type": "target", "id": "abc", "label": "example.test", "serializer_version": "v1"},
		},
		"turn_grant": strings.Repeat("g", 32),
		"expires_at": time.Now().Add(time.Minute).UTC().Format(time.RFC3339),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}
