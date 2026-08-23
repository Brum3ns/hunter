package operational

import (
	"encoding/json"
	"regexp"
	"slices"
	"strings"
)

const maxID int64 = 9_999_999_999_999_999

var (
	variableName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,254}$`)
	secretName   = regexp.MustCompile(`(?i)(^|_)(api|access|refresh|auth|session|private)?_?(key|token|secret|password|passwd)($|_)`)
	jobKeys      = []string{"template", "queue_name", "selections", "targets", "target_chunk", "delay"}
	launchKeys   = []string{"playbook_id", "inventory_id", "credential_id", "variable_set_ids", "overrides", "host_limit", "check_mode", "timeout_seconds"}
)

func schema(properties map[string]any, required []string) json.RawMessage {
	if properties == nil {
		properties = map[string]any{}
	}
	root := map[string]any{"type": "object", "additionalProperties": false, "properties": properties}
	if len(required) > 0 {
		root["required"] = required
	}
	encoded, _ := json.Marshal(root)
	return encoded
}

func stringProperty(max int) map[string]any {
	return map[string]any{"type": "string", "maxLength": max}
}
func intProperty(min, max int64) map[string]any {
	return map[string]any{"type": "integer", "minimum": min, "maximum": max}
}
func idArrayProperty(min, max int) map[string]any {
	return map[string]any{"type": "array", "minItems": min, "maxItems": max, "uniqueItems": true,
		"items": intProperty(1, maxID)}
}
func objectProperty(properties map[string]any, required []string) map[string]any {
	value := map[string]any{"type": "object", "additionalProperties": false, "properties": properties}
	if len(required) > 0 {
		value["required"] = required
	}
	return value
}

func templateValidationSchema() json.RawMessage {
	command := objectProperty(map[string]any{
		"command": stringProperty(255), "operator": stringProperty(2),
		"args": map[string]any{"type": "array", "maxItems": 200, "items": stringProperty(4096)},
	}, []string{"command"})
	template := objectProperty(map[string]any{
		"name": stringProperty(200), "kind": stringProperty(40), "description": stringProperty(4000),
		"tags":   map[string]any{"type": "array", "maxItems": 50, "items": stringProperty(200)},
		"output": stringProperty(4000), "commands": map[string]any{"type": "array", "minItems": 1, "maxItems": 50, "items": command},
		"target": objectProperty(map[string]any{"type": stringProperty(100), "separator": stringProperty(20), "output": stringProperty(4000)}, nil),
	}, []string{"name", "kind", "commands"})
	return schema(map[string]any{"template": template}, []string{"template"})
}

func jobSchema(requireTemplate bool) json.RawMessage {
	selection := objectProperty(map[string]any{
		"source":      map[string]any{"type": "string", "enum": []string{"targets", "sitemap"}},
		"q":           stringProperty(500),
		"ids":         map[string]any{"type": "array", "maxItems": 10_000, "items": stringProperty(255)},
		"exclude_ids": map[string]any{"type": "array", "maxItems": 10_000, "items": stringProperty(255)},
	}, []string{"source"})
	props := map[string]any{
		"template": stringProperty(255), "queue_name": stringProperty(100),
		"selections":   map[string]any{"type": "array", "maxItems": 100, "items": selection},
		"targets":      map[string]any{"type": "array", "maxItems": 10_000, "items": stringProperty(8192)},
		"target_chunk": intProperty(0, 1_000_000), "delay": intProperty(0, 86_400_000),
	}
	required := []string{}
	if requireTemplate {
		required = append(required, "template")
	}
	return schema(props, required)
}

func inventoryFields(required bool) map[string]any {
	_ = required
	return map[string]any{
		"name": stringProperty(255), "description": stringProperty(4000), "yaml_content": stringProperty(262_144),
		"default_credential_id": map[string]any{"type": []string{"integer", "null"}, "minimum": 1, "maximum": maxID},
		"variable_set_ids":      idArrayProperty(0, 100),
	}
}

func inventoryCreateSchema() json.RawMessage {
	return schema(map[string]any{"inventory": objectProperty(inventoryFields(true), []string{"name", "yaml_content"})}, []string{"inventory"})
}
func inventoryEditSchema() json.RawMessage {
	return schema(map[string]any{
		"id": intProperty(1, maxID), "expected_lock_version": intProperty(0, maxID),
		"changes": objectProperty(inventoryFields(false), nil),
	}, []string{"id", "expected_lock_version", "changes"})
}

func hostKeySchema() json.RawMessage {
	candidate := objectProperty(map[string]any{
		"host": stringProperty(512), "port": intProperty(1, 65_535),
		"known_hosts_line": stringProperty(16_384), "expected_fingerprint": stringProperty(512),
		"scanned_fingerprint": stringProperty(512),
	}, []string{"host", "port", "known_hosts_line", "expected_fingerprint", "scanned_fingerprint"})
	return schema(map[string]any{
		"id": intProperty(1, maxID), "expected_lock_version": intProperty(0, maxID),
		"candidates": map[string]any{"type": "array", "minItems": 1, "maxItems": 1000, "items": candidate},
	}, []string{"id", "expected_lock_version", "candidates"})
}

func variableSetFields() map[string]any {
	return map[string]any{"name": stringProperty(255), "description": map[string]any{"type": []string{"string", "null"}, "maxLength": 4000}}
}
func variableSetCreateSchema() json.RawMessage {
	return schema(map[string]any{"variable_set": objectProperty(variableSetFields(), []string{"name"})}, []string{"variable_set"})
}
func variableSetEditSchema() json.RawMessage {
	return schema(map[string]any{
		"id": intProperty(1, maxID), "expected_lock_version": intProperty(0, maxID),
		"changes": objectProperty(variableSetFields(), nil),
	}, []string{"id", "expected_lock_version", "changes"})
}

func variableFields() map[string]any {
	return map[string]any{
		"name": stringProperty(255), "value_type": map[string]any{"type": "string", "enum": []string{"string", "number", "boolean", "list", "dictionary"}},
		"value": map[string]any{}, "position": intProperty(0, 1_000_000),
	}
}
func variableCreateSchema() json.RawMessage {
	return schema(map[string]any{
		"variable_set_id": intProperty(1, maxID),
		"variable":        objectProperty(variableFields(), []string{"name", "value_type", "value"}),
	}, []string{"variable_set_id", "variable"})
}
func variableEditSchema() json.RawMessage {
	return schema(map[string]any{
		"variable_set_id": intProperty(1, maxID), "id": intProperty(1, maxID),
		"expected_lock_version": intProperty(0, maxID), "changes": objectProperty(variableFields(), nil),
	}, []string{"variable_set_id", "id", "expected_lock_version", "changes"})
}

func launchSchema() json.RawMessage {
	override := objectProperty(map[string]any{
		"name": stringProperty(255), "value_type": map[string]any{"type": "string", "enum": []string{"string", "number", "boolean", "list", "dictionary"}},
		"value": map[string]any{},
	}, []string{"name", "value_type", "value"})
	return schema(map[string]any{
		"playbook_id": intProperty(1, maxID), "inventory_id": intProperty(1, maxID),
		"credential_id":    map[string]any{"type": []string{"integer", "null"}, "minimum": 1, "maximum": maxID},
		"variable_set_ids": idArrayProperty(0, 100),
		"overrides":        map[string]any{"type": "array", "maxItems": 100, "items": override},
		"host_limit":       map[string]any{"type": []string{"string", "null"}, "maxLength": 255},
		"check_mode":       map[string]any{"type": "boolean"}, "timeout_seconds": intProperty(60, 86_400),
	}, []string{"playbook_id", "inventory_id"})
}

func validateString(key string, max int) inputValidator {
	return func(raw rawInput) bool {
		if !exact(raw, []string{key}, []string{key}) {
			return false
		}
		value, ok := rawString(raw[key])
		return ok && len(value) <= max
	}
}

func validatePositiveIDs(keys ...string) inputValidator {
	return func(raw rawInput) bool {
		if !exact(raw, keys, keys) {
			return false
		}
		for _, key := range keys {
			if value, ok := rawInt(raw[key]); !ok || value < 1 || value > maxID {
				return false
			}
		}
		return true
	}
}

func validateOptionalPositiveID(required string, optional string) inputValidator {
	return func(raw rawInput) bool {
		if !exact(raw, []string{required, optional}, []string{required}) {
			return false
		}
		if value, ok := rawInt(raw[required]); !ok || value < 1 || value > maxID {
			return false
		}
		if value, present := raw[optional]; present {
			id, ok := rawInt(value)
			return ok && id > 0 && id <= maxID
		}
		return true
	}
}

func validateIDArray(key string, min, max int) inputValidator {
	return func(raw rawInput) bool {
		return exact(raw, []string{key}, []string{key}) && validIDArray(raw[key], min, max)
	}
}

func validateTemplate(raw rawInput) bool {
	if !exact(raw, []string{"template"}, []string{"template"}) {
		return false
	}
	template, ok := rawObject(raw["template"])
	if !ok || !exact(template, []string{"name", "kind", "tags", "description", "output", "commands", "target"}, []string{"name", "kind", "commands"}) {
		return false
	}
	name, nameOK := rawString(template["name"])
	kind, kindOK := rawString(template["kind"])
	var commands []rawInput
	if !nameOK || strings.TrimSpace(name) == "" || len(name) > 200 || !kindOK || (kind != "cmdscript" && kind != "workflow") ||
		json.Unmarshal(template["commands"], &commands) != nil || len(commands) == 0 || len(commands) > 50 {
		return false
	}
	for _, command := range commands {
		if !exact(command, []string{"command", "operator", "args"}, []string{"command"}) {
			return false
		}
		text, ok := rawString(command["command"])
		if !ok || strings.TrimSpace(text) == "" || len(text) > 255 ||
			!optionalOperator(command) || !optionalStringArray(command, "args", 200, 4096) {
			return false
		}
	}
	if targetRaw, present := template["target"]; present {
		target, ok := rawObject(targetRaw)
		if !ok || !exact(target, []string{"type", "separator", "output"}, nil) ||
			!optionalString(target, "type", 100) || !optionalString(target, "separator", 20) || !optionalString(target, "output", 4000) {
			return false
		}
	}
	return optionalString(template, "description", 4000) && optionalString(template, "output", 4000) && optionalStringArray(template, "tags", 50, 200)
}

func validateJob(requireTemplate bool) inputValidator {
	return func(raw rawInput) bool {
		required := []string{}
		if requireTemplate {
			required = append(required, "template")
		}
		if !exact(raw, jobKeys, required) || !optionalString(raw, "template", 255) || !optionalString(raw, "queue_name", 100) ||
			!optionalInt(raw, "target_chunk", 0, 1_000_000) || !optionalInt(raw, "delay", 0, 86_400_000) ||
			!optionalStringArray(raw, "targets", 10_000, 8192) {
			return false
		}
		if requireTemplate {
			name, ok := rawString(raw["template"])
			if !ok || strings.TrimSpace(name) == "" {
				return false
			}
		}
		if encoded, present := raw["selections"]; present {
			var selections []rawInput
			if json.Unmarshal(encoded, &selections) != nil || len(selections) > 100 {
				return false
			}
			for _, selection := range selections {
				if !exact(selection, []string{"source", "q", "ids", "exclude_ids"}, []string{"source"}) {
					return false
				}
				source, ok := rawString(selection["source"])
				if !ok || !slices.Contains([]string{"targets", "sitemap"}, source) || !optionalString(selection, "q", 500) ||
					!optionalStringArray(selection, "ids", 10_000, 255) || !optionalStringArray(selection, "exclude_ids", 10_000, 255) {
					return false
				}
			}
		}
		return true
	}
}

func validateInventoryCreate(raw rawInput) bool {
	if !exact(raw, []string{"inventory"}, []string{"inventory"}) {
		return false
	}
	value, ok := rawObject(raw["inventory"])
	return ok && validInventory(value, true)
}
func validateInventoryEdit(raw rawInput) bool {
	if !exact(raw, []string{"id", "expected_lock_version", "changes"}, []string{"id", "expected_lock_version", "changes"}) ||
		!positiveRaw(raw["id"]) || !nonnegativeRaw(raw["expected_lock_version"]) {
		return false
	}
	value, ok := rawObject(raw["changes"])
	return ok && len(value) > 0 && validInventory(value, false)
}
func validInventory(value rawInput, create bool) bool {
	required := []string{}
	if create {
		required = []string{"name", "yaml_content"}
	}
	if !exact(value, []string{"name", "description", "yaml_content", "default_credential_id", "variable_set_ids"}, required) ||
		!optionalString(value, "name", 255) || !optionalString(value, "description", 4000) ||
		!optionalString(value, "yaml_content", 262_144) || !optionalNullablePositiveInt(value, "default_credential_id") {
		return false
	}
	if create {
		name, nok := rawString(value["name"])
		yaml, yok := rawString(value["yaml_content"])
		if !nok || !yok || strings.TrimSpace(name) == "" || strings.TrimSpace(yaml) == "" {
			return false
		}
	}
	return optionalIDArray(value, "variable_set_ids", 100)
}

func validateHostKeys(raw rawInput) bool {
	if !exact(raw, []string{"id", "expected_lock_version", "candidates"}, []string{"id", "expected_lock_version", "candidates"}) ||
		!positiveRaw(raw["id"]) || !nonnegativeRaw(raw["expected_lock_version"]) {
		return false
	}
	var candidates []rawInput
	if json.Unmarshal(raw["candidates"], &candidates) != nil || len(candidates) == 0 || len(candidates) > 1000 {
		return false
	}
	keys := []string{"expected_fingerprint", "host", "known_hosts_line", "port", "scanned_fingerprint"}
	for _, candidate := range candidates {
		if !exact(candidate, keys, keys) || !positiveRaw(candidate["port"]) {
			return false
		}
		for _, key := range []string{"expected_fingerprint", "host", "known_hosts_line", "scanned_fingerprint"} {
			if value, ok := rawString(candidate[key]); !ok || value == "" || len(value) > 16_384 {
				return false
			}
		}
	}
	return true
}

func validateVariableSetCreate(raw rawInput) bool {
	if !exact(raw, []string{"variable_set"}, []string{"variable_set"}) {
		return false
	}
	value, ok := rawObject(raw["variable_set"])
	return ok && validVariableSet(value, true)
}
func validateVariableSetEdit(raw rawInput) bool {
	if !exact(raw, []string{"id", "expected_lock_version", "changes"}, []string{"id", "expected_lock_version", "changes"}) ||
		!positiveRaw(raw["id"]) || !nonnegativeRaw(raw["expected_lock_version"]) {
		return false
	}
	value, ok := rawObject(raw["changes"])
	return ok && len(value) > 0 && validVariableSet(value, false)
}
func validVariableSet(value rawInput, create bool) bool {
	required := []string{}
	if create {
		required = []string{"name"}
	}
	if !exact(value, []string{"name", "description"}, required) || !optionalString(value, "name", 255) ||
		!optionalNullableString(value, "description", 4000) {
		return false
	}
	if create {
		name, ok := rawString(value["name"])
		return ok && strings.TrimSpace(name) != ""
	}
	return true
}

func validateVariableCreate(raw rawInput) bool {
	if !exact(raw, []string{"variable_set_id", "variable"}, []string{"variable_set_id", "variable"}) || !positiveRaw(raw["variable_set_id"]) {
		return false
	}
	value, ok := rawObject(raw["variable"])
	return ok && validVariable(value, true)
}
func validateVariableEdit(raw rawInput) bool {
	if !exact(raw, []string{"variable_set_id", "id", "expected_lock_version", "changes"}, []string{"variable_set_id", "id", "expected_lock_version", "changes"}) ||
		!positiveRaw(raw["variable_set_id"]) || !positiveRaw(raw["id"]) || !nonnegativeRaw(raw["expected_lock_version"]) {
		return false
	}
	value, ok := rawObject(raw["changes"])
	return ok && len(value) > 0 && validVariable(value, false)
}
func validVariable(value rawInput, create bool) bool {
	required := []string{}
	if create {
		required = []string{"name", "value_type", "value"}
	}
	if !exact(value, []string{"name", "value_type", "value", "position"}, required) || !optionalInt(value, "position", 0, 1_000_000) {
		return false
	}
	if nameRaw, present := value["name"]; present {
		name, ok := rawString(nameRaw)
		if !ok || !variableName.MatchString(name) || secretName.MatchString(name) {
			return false
		}
	}
	if typeRaw, present := value["value_type"]; present {
		kind, ok := rawString(typeRaw)
		if !ok || !slices.Contains([]string{"string", "number", "boolean", "list", "dictionary"}, kind) {
			return false
		}
	}
	return true
}

func validateLaunch(raw rawInput) bool {
	if !exact(raw, launchKeys, []string{"playbook_id", "inventory_id"}) || !positiveRaw(raw["playbook_id"]) || !positiveRaw(raw["inventory_id"]) ||
		!optionalNullablePositiveInt(raw, "credential_id") || !optionalIDArray(raw, "variable_set_ids", 100) ||
		!optionalNullableString(raw, "host_limit", 255) || !optionalBool(raw, "check_mode") || !optionalInt(raw, "timeout_seconds", 60, 86_400) {
		return false
	}
	if encoded, present := raw["overrides"]; present {
		var overrides []rawInput
		if json.Unmarshal(encoded, &overrides) != nil || len(overrides) > 100 {
			return false
		}
		for _, override := range overrides {
			if !exact(override, []string{"name", "value_type", "value"}, []string{"name", "value_type", "value"}) || !validVariable(override, true) {
				return false
			}
		}
	}
	return true
}

func rawObject(raw json.RawMessage) (rawInput, bool) {
	var value rawInput
	return value, json.Unmarshal(raw, &value) == nil
}
func rawString(raw json.RawMessage) (string, bool) {
	var value string
	return value, json.Unmarshal(raw, &value) == nil
}
func rawInt(raw json.RawMessage) (int64, bool) {
	var value int64
	return value, json.Unmarshal(raw, &value) == nil
}
func positiveRaw(raw json.RawMessage) bool {
	value, ok := rawInt(raw)
	return ok && value > 0 && value <= maxID
}
func nonnegativeRaw(raw json.RawMessage) bool {
	value, ok := rawInt(raw)
	return ok && value >= 0 && value <= maxID
}

func optionalString(raw rawInput, key string, max int) bool {
	value, present := raw[key]
	if !present {
		return true
	}
	text, ok := rawString(value)
	return ok && len(text) <= max
}
func optionalOperator(raw rawInput) bool {
	value, present := raw["operator"]
	if !present {
		return true
	}
	operator, ok := rawString(value)
	return ok && slices.Contains([]string{"", "|", "&&", "||"}, operator)
}
func optionalNullableString(raw rawInput, key string, max int) bool {
	value, present := raw[key]
	return !present || string(value) == "null" || optionalString(raw, key, max)
}
func optionalInt(raw rawInput, key string, min, max int64) bool {
	value, present := raw[key]
	if !present {
		return true
	}
	number, ok := rawInt(value)
	return ok && number >= min && number <= max
}
func optionalBool(raw rawInput, key string) bool {
	value, present := raw[key]
	if !present {
		return true
	}
	var decoded bool
	return json.Unmarshal(value, &decoded) == nil
}
func optionalNullablePositiveInt(raw rawInput, key string) bool {
	value, present := raw[key]
	return !present || string(value) == "null" || positiveRaw(value)
}
func validStringArray(raw json.RawMessage, min, max, maxLen int) bool {
	var values []string
	if json.Unmarshal(raw, &values) != nil || len(values) < min || len(values) > max {
		return false
	}
	for _, value := range values {
		if len(value) > maxLen {
			return false
		}
	}
	return true
}
func optionalStringArray(raw rawInput, key string, max, maxLen int) bool {
	value, present := raw[key]
	return !present || validStringArray(value, 0, max, maxLen)
}
func validIDArray(raw json.RawMessage, min, max int) bool {
	var ids []int64
	if json.Unmarshal(raw, &ids) != nil || len(ids) < min || len(ids) > max {
		return false
	}
	seen := map[int64]struct{}{}
	for _, id := range ids {
		if id < 1 || id > maxID {
			return false
		}
		if _, duplicate := seen[id]; duplicate {
			return false
		}
		seen[id] = struct{}{}
	}
	return true
}
func optionalIDArray(raw rawInput, key string, max int) bool {
	value, present := raw[key]
	return !present || validIDArray(value, 0, max)
}
