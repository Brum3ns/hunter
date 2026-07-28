package readmodule

import (
	"encoding/json"
	"errors"

	"hunter.local/assistant/mcp/internal/codec"
)

var errRejected = errors.New("tool response rejected")

func validateList(spec Spec) func([]byte) error {
	max := spec.maxItems()
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if err := codec.DecodeRawClosed(payload, &root); err != nil {
			return err
		}
		if !codec.ExactKeys(root, []string{"correlation_id", "count", "page", "limit", "items"}) {
			return errRejected
		}
		var out struct {
			CorrelationID string                       `json:"correlation_id"`
			Count         int                          `json:"count"`
			Page          int                          `json:"page"`
			Limit         int                          `json:"limit"`
			Items         []map[string]json.RawMessage `json:"items"`
		}
		if json.Unmarshal(payload, &out) != nil || !UUIDPattern.MatchString(out.CorrelationID) {
			return errRejected
		}
		if out.Count < 0 || out.Page < 1 || out.Limit < 1 || out.Limit > max || len(out.Items) > out.Limit {
			return errRejected
		}
		for _, item := range out.Items {
			if !codec.ExactKeys(item, spec.SummaryKeys) {
				return errRejected
			}
		}
		return nil
	}
}

func validateGet(spec Spec) func([]byte) error {
	return func(payload []byte) error {
		var root map[string]json.RawMessage
		if err := codec.DecodeRawClosed(payload, &root); err != nil {
			return err
		}
		if !codec.ExactKeys(root, []string{"correlation_id", spec.DetailKey}) {
			return errRejected
		}
		var correlation string
		if json.Unmarshal(root["correlation_id"], &correlation) != nil || !UUIDPattern.MatchString(correlation) {
			return errRejected
		}
		var detail map[string]json.RawMessage
		if codec.DecodeRawClosed(root[spec.DetailKey], &detail) != nil {
			return errRejected
		}
		if !codec.ExactKeys(detail, spec.FullKeys) {
			return errRejected
		}
		return nil
	}
}
