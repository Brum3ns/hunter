package worker

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"hunter.local/assistant/validator/internal/check"
)

const (
	testValidationID  = "123e4567-e89b-42d3-a456-426614174000"
	testCorrelationID = "123e4567-e89b-42d3-a456-426614174001"
)

type checkerFunc func(context.Context, string) check.Result

func (function checkerFunc) Check(ctx context.Context, source string) check.Result {
	return function(ctx, source)
}

func validJob(now time.Time) map[string]any {
	return map[string]any{
		"schema_version": 1,
		"validation_id":  testValidationID,
		"correlation_id": testCorrelationID,
		"turn_id":        7,
		"source":         "---\n- hosts: workers\n  tasks: []\n",
		"expires_at":     now.Add(time.Minute).UTC().Format(time.RFC3339),
	}
}

func encoded(t *testing.T, value any) []byte {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func TestDecodeJobAcceptsOnlyTheClosedShortLivedContract(t *testing.T) {
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	job, err := DecodeJob(encoded(t, validJob(now)), now)
	if err != nil || job.ValidationID != testValidationID || job.TurnID != 7 {
		t.Fatalf("job=%+v err=%v", job, err)
	}

	tests := map[string]func(map[string]any){
		"unknown field":      func(value map[string]any) { value["command"] = "id" },
		"old schema":         func(value map[string]any) { value["schema_version"] = 0 },
		"invalid UUID":       func(value map[string]any) { value["validation_id"] = "not-a-uuid" },
		"empty source":       func(value map[string]any) { value["source"] = "" },
		"oversized source":   func(value map[string]any) { value["source"] = strings.Repeat("x", 65_537) },
		"expired":            func(value map[string]any) { value["expires_at"] = now.Format(time.RFC3339) },
		"excessive lifetime": func(value map[string]any) { value["expires_at"] = now.Add(6 * time.Minute).Format(time.RFC3339) },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			value := validJob(now)
			mutate(value)
			if _, err := DecodeJob(encoded(t, value), now); !errors.Is(err, ErrInvalidJob) {
				t.Fatalf("err=%v", err)
			}
		})
	}
}

func TestProcessorReturnsAClosedRedactedTerminalEvent(t *testing.T) {
	job, err := DecodeJob(encoded(t, validJob(time.Now().UTC())), time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	processor := Processor{
		Checker: checkerFunc(func(_ context.Context, source string) check.Result {
			if !strings.Contains(source, "hosts") {
				t.Fatalf("source=%q", source)
			}
			return check.Result{Status: "invalid", Codes: []string{"ansible_syntax_invalid"}}
		}),
	}

	event := processor.Process(context.Background(), job)
	if event.SchemaVersion != 1 || event.ValidationID != job.ValidationID || event.CorrelationID != job.CorrelationID || event.Status != "invalid" {
		t.Fatalf("event=%+v", event)
	}
	if !slices.Equal(event.Codes, []string{"ansible_syntax_invalid"}) || !uuidPattern.MatchString(event.EventID) {
		t.Fatalf("event=%+v", event)
	}
	body := string(encoded(t, event))
	if strings.Contains(body, job.Source) || strings.Contains(body, "stderr") {
		t.Fatalf("event leaked validator material: %s", body)
	}
}

func TestProcessorFailsClosedForInvalidCheckerOutput(t *testing.T) {
	job, _ := DecodeJob(encoded(t, validJob(time.Now().UTC())), time.Now().UTC())
	processor := Processor{Checker: checkerFunc(func(context.Context, string) check.Result {
		return check.Result{Status: "valid", Codes: []string{"password=hunter"}}
	})}

	event := processor.Process(context.Background(), job)
	if event.Status != "failed" || !slices.Equal(event.Codes, []string{"validator_failed"}) {
		t.Fatalf("event=%+v", event)
	}
}
