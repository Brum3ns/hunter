// Package actionreceipt validates the one closed response shared by every
// effectful Hunter MCP tool.
package actionreceipt

import (
	"encoding/json"
	"errors"
	"regexp"
	"time"

	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
)

var (
	errRejected   = errors.New("tool response rejected")
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
	safeSlug      = regexp.MustCompile(`^[a-z][a-z0-9_]{0,63}$`)
)

// Schema is the advertised MCP {result: ...} envelope for effect receipts.
// Runtime validation below remains the authoritative semantic check.
func Schema() json.RawMessage {
	return json.RawMessage(`{
		"type":"object","additionalProperties":false,"required":["result"],
		"properties":{"result":{"type":"object","additionalProperties":false,
			"required":["correlation_id","receipt"],"properties":{
				"correlation_id":{"type":"string","format":"uuid"},
				"receipt":{"type":"object","additionalProperties":false,
					"required":["receipt_id","tool","status","target","human_user_id","turn_id","idempotency_digest","replayed","occurred_at"],
					"properties":{
						"receipt_id":{"type":"string","format":"uuid"},"tool":{"type":"string"},"status":{"type":"string"},
						"target":{"type":"object","additionalProperties":false,"required":["type","id"],"properties":{"type":{"type":"string"},"id":{"type":"string"}}},
						"human_user_id":{"type":"integer","minimum":1},"turn_id":{"type":"integer","minimum":1},
						"idempotency_digest":{"type":"string","pattern":"^[0-9a-f]{64}$"},"replayed":{"type":"boolean"},
						"occurred_at":{"type":"string","format":"date-time"}
					}
				}
			}
		}}
	}`)
}

func Validate(expectedTool string) func([]byte) error {
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if codec.DecodeRawClosed(payload, &root) != nil ||
			!codec.ExactKeys(root, []string{"correlation_id", "receipt"}) {
			return errRejected
		}
		var correlation string
		if json.Unmarshal(root["correlation_id"], &correlation) != nil || !readmodule.UUIDPattern.MatchString(correlation) {
			return errRejected
		}
		var receipt map[string]json.RawMessage
		if codec.DecodeRawClosed(root["receipt"], &receipt) != nil || !codec.ExactKeys(receipt,
			[]string{"receipt_id", "tool", "status", "target", "human_user_id", "turn_id", "idempotency_digest", "replayed", "occurred_at"}) {
			return errRejected
		}
		var receiptID, toolName, status, digest, occurredAt string
		var userID, turnID int64
		var replayed bool
		if json.Unmarshal(receipt["receipt_id"], &receiptID) != nil || !uuidPattern.MatchString(receiptID) ||
			json.Unmarshal(receipt["tool"], &toolName) != nil || toolName != expectedTool ||
			json.Unmarshal(receipt["status"], &status) != nil || !safeSlug.MatchString(status) ||
			json.Unmarshal(receipt["human_user_id"], &userID) != nil || userID <= 0 ||
			json.Unmarshal(receipt["turn_id"], &turnID) != nil || turnID <= 0 ||
			json.Unmarshal(receipt["idempotency_digest"], &digest) != nil || !digestPattern.MatchString(digest) ||
			json.Unmarshal(receipt["replayed"], &replayed) != nil ||
			json.Unmarshal(receipt["occurred_at"], &occurredAt) != nil {
			return errRejected
		}
		if _, err := time.Parse(time.RFC3339, occurredAt); err != nil {
			return errRejected
		}
		var target map[string]json.RawMessage
		if codec.DecodeRawClosed(receipt["target"], &target) != nil ||
			!codec.ExactKeys(target, []string{"type", "id"}) {
			return errRejected
		}
		var targetType, targetID string
		if json.Unmarshal(target["type"], &targetType) != nil || !safeSlug.MatchString(targetType) ||
			json.Unmarshal(target["id"], &targetID) != nil || !codec.SafeID.MatchString(targetID) {
			return errRejected
		}
		return nil
	}
}
