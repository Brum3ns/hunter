package actionreceipt

import (
	"strings"
	"testing"
)

const validReceipt = `{
	"correlation_id":"3b241101-e2bb-4255-8caf-4136c566a962",
	"receipt":{
		"receipt_id":"3b241101-e2bb-4255-8caf-4136c566a963",
		"tool":"create_vulnerability","status":"created",
		"target":{"type":"vulnerability","id":"507f1f77bcf86cd799439011"},
		"human_user_id":1,"turn_id":null,
		"idempotency_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"replayed":false,"occurred_at":"2026-08-19T00:00:00Z"
	}
}`

func TestValidateAcceptsNullOrPositiveTurnID(t *testing.T) {
	validate := Validate("create_vulnerability")
	for _, payload := range []string{
		validReceipt,
		strings.Replace(validReceipt, `"turn_id":null`, `"turn_id":42`, 1),
	} {
		if err := validate([]byte(payload)); err != nil {
			t.Fatalf("valid receipt rejected: %v", err)
		}
	}
}

func TestValidateRejectsInvalidTurnIDAndNonClosedReceipts(t *testing.T) {
	validate := Validate("create_vulnerability")
	for name, payload := range map[string]string{
		"zero":     strings.Replace(validReceipt, `"turn_id":null`, `"turn_id":0`, 1),
		"negative": strings.Replace(validReceipt, `"turn_id":null`, `"turn_id":-1`, 1),
		"string":   strings.Replace(validReceipt, `"turn_id":null`, `"turn_id":"1"`, 1),
		"missing":  strings.Replace(validReceipt, `"human_user_id":1,"turn_id":null,`, `"human_user_id":1,`, 1),
		"extra":    strings.Replace(validReceipt, `"turn_id":null,`, `"turn_id":null,"secret":"x",`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			if err := validate([]byte(payload)); err == nil {
				t.Fatal("invalid receipt accepted")
			}
		})
	}
}
