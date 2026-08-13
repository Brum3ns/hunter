package readmodule

import (
	"bytes"
	"encoding/json"
	"math"

	"hunter.local/assistant/mcp/internal/codec"
)

// ExactObject validates a closed nested object without accepting duplicate
// keys or trailing JSON values.
func ExactObject(raw json.RawMessage, keys []string) bool {
	var object map[string]json.RawMessage
	return codec.DecodeRawClosed(raw, &object) == nil && codec.ExactKeys(object, keys)
}

// ExactObjectArray validates a bounded array of closed nested objects.
func ExactObjectArray(raw json.RawMessage, keys []string, max int) bool {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil || len(items) > max {
		return false
	}
	for _, item := range items {
		if !ExactObject(item, keys) {
			return false
		}
	}
	return true
}

// TypedObject validates exact keys and then their value contracts.
func TypedObject(raw json.RawMessage, keys []string, validate func(map[string]json.RawMessage) bool) bool {
	var object map[string]json.RawMessage
	return codec.DecodeRawClosed(raw, &object) == nil && codec.ExactKeys(object, keys) && validate(object)
}

// TypedObjectArray validates a bounded array of exact, typed objects.
func TypedObjectArray(raw json.RawMessage, keys []string, max int, validate func(map[string]json.RawMessage) bool) bool {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil || len(items) > max {
		return false
	}
	for _, item := range items {
		if !TypedObject(item, keys, validate) {
			return false
		}
	}
	return true
}

func StringValue(raw json.RawMessage, maxBytes int, nullable bool) bool {
	if nullable && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return true
	}
	var value string
	return json.Unmarshal(raw, &value) == nil && len(value) <= maxBytes
}

func BooleanValue(raw json.RawMessage, nullable bool) bool {
	if nullable && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return true
	}
	var value bool
	return json.Unmarshal(raw, &value) == nil
}

func IntegerValue(raw json.RawMessage, minValue, maxValue int64, nullable bool) bool {
	if nullable && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return true
	}
	var value int64
	return json.Unmarshal(raw, &value) == nil && value >= minValue && value <= maxValue
}

func NumberValue(raw json.RawMessage, nullable bool) bool {
	if nullable && bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return true
	}
	var value float64
	return json.Unmarshal(raw, &value) == nil && !math.IsNaN(value) && !math.IsInf(value, 0)
}

func BoundedStringArray(raw json.RawMessage, maxItems, maxStringBytes int) bool {
	var items []json.RawMessage
	if json.Unmarshal(raw, &items) != nil || len(items) > maxItems {
		return false
	}
	for _, item := range items {
		if !StringValue(item, maxStringBytes, false) {
			return false
		}
	}
	return true
}

func StringArray(raw json.RawMessage, max int) bool {
	return BoundedStringArray(raw, max, 65_536)
}

func IntegerArray(raw json.RawMessage, max int) bool {
	var items []int64
	return json.Unmarshal(raw, &items) == nil && len(items) <= max
}

func BoundedIntegerArray(raw json.RawMessage, maxItems int, minValue, maxValue int64, unique bool) bool {
	var items []int64
	if json.Unmarshal(raw, &items) != nil || len(items) > maxItems {
		return false
	}
	seen := make(map[int64]struct{}, len(items))
	for _, value := range items {
		if value < minValue || value > maxValue {
			return false
		}
		if unique {
			if _, duplicate := seen[value]; duplicate {
				return false
			}
			seen[value] = struct{}{}
		}
	}
	return true
}
