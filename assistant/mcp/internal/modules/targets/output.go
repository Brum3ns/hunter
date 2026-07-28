package targets

import (
	"encoding/json"
	"errors"
	"regexp"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = errors.New("tool response rejected")

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

const maxItems = 50

type listOutput struct {
	CorrelationID string        `json:"correlation_id"`
	Count         int           `json:"count"`
	Page          int           `json:"page"`
	Limit         int           `json:"limit"`
	Items         []summaryItem `json:"items"`
}

type summaryItem struct {
	ID         string  `json:"id"`
	Host       *string `json:"host"`
	Program    *string `json:"program"`
	StatusCode *int    `json:"status_code"`
	Title      *string `json:"title"`
}

func validateListOutput(payload []byte) error {
	var root map[string]json.RawMessage
	if err := codec.DecodeRawClosed(payload, &root); err != nil {
		return err
	}
	if !codec.ExactKeys(root, []string{"correlation_id", "count", "page", "limit", "items"}) {
		return errRejected
	}
	var out listOutput
	if codec.DecodeRawClosed(payload, &out) != nil || !uuidPattern.MatchString(out.CorrelationID) {
		return errRejected
	}
	if out.Count < 0 || out.Page < 1 || out.Limit < 1 || out.Limit > maxItems || len(out.Items) > out.Limit {
		return errRejected
	}
	// Re-validate each item as a closed object with exactly the summary keys.
	var shape struct {
		Items []map[string]json.RawMessage `json:"items"`
	}
	if err := json.Unmarshal(payload, &shape); err != nil {
		return errRejected
	}
	for _, item := range shape.Items {
		if !codec.ExactKeys(item, []string{"id", "host", "program", "status_code", "title"}) {
			return errRejected
		}
	}
	return nil
}

func validateGetOutput(payload []byte) error {
	var root map[string]json.RawMessage
	if err := codec.DecodeRawClosed(payload, &root); err != nil {
		return err
	}
	if !codec.ExactKeys(root, []string{"correlation_id", "target"}) {
		return errRejected
	}
	var correlation string
	if json.Unmarshal(root["correlation_id"], &correlation) != nil || !uuidPattern.MatchString(correlation) {
		return errRejected
	}
	var target map[string]json.RawMessage
	if codec.DecodeRawClosed(root["target"], &target) != nil {
		return errRejected
	}
	return exactTargetKeys(target)
}

func exactTargetKeys(target map[string]json.RawMessage) error {
	if !codec.ExactKeys(target, []string{
		"id", "host", "program", "status_code", "title",
		"url", "status_family", "webserver", "content_type",
		"port", "scheme", "tech", "seen_at", "page_type",
	}) {
		return errRejected
	}
	return nil
}
