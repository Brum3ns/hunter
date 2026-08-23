package operational

import (
	"encoding/json"
	"errors"
	"strings"
	"time"

	"hunter.local/assistant/mcp/internal/actionreceipt"
	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/readmodule"
)

var errRejected = errors.New("tool response rejected")

func validateValidation(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "valid", "codes"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var valid bool
	var codes []string
	if json.Unmarshal(root["valid"], &valid) != nil || json.Unmarshal(root["codes"], &codes) != nil || len(codes) > 100 {
		return errRejected
	}
	for _, code := range codes {
		if len(code) == 0 || len(code) > 255 {
			return errRejected
		}
	}
	return nil
}

func validateTargetResolution(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "count", "truncated", "sample"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var count int64
	var truncated bool
	var sample []string
	if json.Unmarshal(root["count"], &count) != nil || count < 0 ||
		json.Unmarshal(root["truncated"], &truncated) != nil || json.Unmarshal(root["sample"], &sample) != nil || len(sample) > 50 {
		return errRejected
	}
	for _, value := range sample {
		if len(value) == 0 || len(value) > 8192 {
			return errRejected
		}
	}
	return nil
}

func validateControlCenterHealth(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "health"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var health map[string]json.RawMessage
	if codec.DecodeRawClosed(root["health"], &health) != nil || !codec.ExactKeys(health, []string{"rabbitmq", "mongo"}) {
		return errRejected
	}
	for _, service := range []string{"rabbitmq", "mongo"} {
		var value map[string]json.RawMessage
		var state bool
		if codec.DecodeRawClosed(health[service], &value) != nil || !codec.ExactKeys(value, []string{"ok"}) ||
			json.Unmarshal(value["ok"], &state) != nil {
			return errRejected
		}
	}
	return nil
}

func validateControlCenterStats(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "stats"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var stats map[string]json.RawMessage
	if codec.DecodeRawClosed(root["stats"], &stats) != nil ||
		!codec.ExactKeys(stats, []string{"totals", "by_status", "top_templates", "by_queue", "daily"}) {
		return errRejected
	}
	var totals map[string]json.RawMessage
	if codec.DecodeRawClosed(stats["totals"], &totals) != nil ||
		!codec.ExactKeys(totals, []string{"jobs", "succeeded", "failed", "pending", "success_rate", "targets", "templates_used"}) {
		return errRejected
	}
	for _, raw := range totals {
		var value float64
		if json.Unmarshal(raw, &value) != nil || value < 0 {
			return errRejected
		}
	}
	if !validLabeledCounts(stats["by_status"], 16, true) || !validLabeledCounts(stats["top_templates"], 8, false) ||
		!validLabeledCounts(stats["by_queue"], 1000, false) || !validDaily(stats["daily"]) {
		return errRejected
	}
	return nil
}

func validLabeledCounts(raw json.RawMessage, max int, color bool) bool {
	var rows []map[string]json.RawMessage
	if json.Unmarshal(raw, &rows) != nil || len(rows) > max {
		return false
	}
	keys := []string{"label", "count"}
	if color {
		keys = append(keys, "color")
	}
	for _, row := range rows {
		if !codec.ExactKeys(row, keys) || !boundedString(row["label"], 255) || !nonnegativeInteger(row["count"]) ||
			(color && !boundedString(row["color"], 32)) {
			return false
		}
	}
	return true
}

func validDaily(raw json.RawMessage) bool {
	var rows []map[string]json.RawMessage
	if json.Unmarshal(raw, &rows) != nil || len(rows) > 31 {
		return false
	}
	for _, row := range rows {
		if !codec.ExactKeys(row, []string{"date", "count"}) || !boundedString(row["date"], 32) || !nonnegativeInteger(row["count"]) {
			return false
		}
	}
	return true
}

func validateUtilityTask(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "utility_task"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var task map[string]json.RawMessage
	keys := []string{
		"id", "inventory_id", "playbook_id", "kind", "status", "result", "result_redacted",
		"error_code", "error_detail", "started_at", "completed_at", "created_at", "updated_at",
	}
	if codec.DecodeRawClosed(root["utility_task"], &task) != nil || !codec.ExactKeys(task, keys) {
		return errRejected
	}
	var result map[string]any
	var redacted bool
	if json.Unmarshal(task["result"], &result) != nil || json.Unmarshal(task["result_redacted"], &redacted) != nil ||
		!boundedString(task["kind"], 64) || !boundedString(task["status"], 64) {
		return errRejected
	}
	return nil
}

func validateExecutorHealth(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "health"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var health map[string]json.RawMessage
	if codec.DecodeRawClosed(root["health"], &health) != nil ||
		!codec.ExactKeys(health, []string{"configured_runners", "active_runners", "last_seen_at", "oldest_queued_age_seconds"}) ||
		!nonnegativeInteger(health["configured_runners"]) || !nonnegativeInteger(health["active_runners"]) ||
		!nullableNonnegativeInteger(health["oldest_queued_age_seconds"]) || !nullableTime(health["last_seen_at"]) {
		return errRejected
	}
	return nil
}

func validateExportReceipt(payload []byte) error {
	root, ok := closedRoot(payload, []string{"correlation_id", "receipt"})
	if !ok || !validCorrelation(root["correlation_id"]) {
		return errRejected
	}
	var receipt map[string]json.RawMessage
	baseKeys := []string{"receipt_id", "tool", "status", "target", "human_user_id", "turn_id", "idempotency_digest", "replayed", "occurred_at"}
	allKeys := append(append([]string{}, baseKeys...), "artifact")
	if codec.DecodeRawClosed(root["receipt"], &receipt) != nil || !codec.ExactKeys(receipt, allKeys) {
		return errRejected
	}
	base := map[string]json.RawMessage{}
	for _, key := range baseKeys {
		base[key] = receipt[key]
	}
	basePayload, _ := json.Marshal(map[string]any{
		"correlation_id": json.RawMessage(root["correlation_id"]), "receipt": base,
	})
	if actionreceipt.Validate("export_ansible_playbooks")(basePayload) != nil {
		return errRejected
	}
	var artifact map[string]json.RawMessage
	if codec.DecodeRawClosed(receipt["artifact"], &artifact) != nil ||
		!codec.ExactKeys(artifact, []string{"kind", "filename", "byte_count", "expires_at", "browser_download_reference"}) ||
		!boundedString(artifact["kind"], 64) || !boundedString(artifact["filename"], 255) ||
		!positiveInteger(artifact["byte_count"]) || !boundedString(artifact["browser_download_reference"], 2048) {
		return errRejected
	}
	var reference, expiry string
	if json.Unmarshal(artifact["browser_download_reference"], &reference) != nil || !strings.HasPrefix(reference, "/assistant/exports/") ||
		json.Unmarshal(artifact["expires_at"], &expiry) != nil {
		return errRejected
	}
	if _, err := time.Parse(time.RFC3339, expiry); err != nil {
		return errRejected
	}
	return nil
}

func closedRoot(payload []byte, keys []string) (map[string]json.RawMessage, bool) {
	var root map[string]json.RawMessage
	return root, codec.DecodeRawClosed(payload, &root) == nil && codec.ExactKeys(root, keys)
}
func validCorrelation(raw json.RawMessage) bool {
	var value string
	return json.Unmarshal(raw, &value) == nil && readmodule.UUIDPattern.MatchString(value)
}
func boundedString(raw json.RawMessage, max int) bool {
	var value string
	return json.Unmarshal(raw, &value) == nil && len(value) <= max
}
func nonnegativeInteger(raw json.RawMessage) bool {
	var value int64
	return json.Unmarshal(raw, &value) == nil && value >= 0
}
func positiveInteger(raw json.RawMessage) bool {
	var value int64
	return json.Unmarshal(raw, &value) == nil && value > 0
}
func nullableNonnegativeInteger(raw json.RawMessage) bool {
	return string(raw) == "null" || nonnegativeInteger(raw)
}
func nullableTime(raw json.RawMessage) bool {
	if string(raw) == "null" {
		return true
	}
	var value string
	if json.Unmarshal(raw, &value) != nil {
		return false
	}
	_, err := time.Parse(time.RFC3339, value)
	return err == nil
}
