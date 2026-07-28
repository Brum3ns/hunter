package provider

// strictUnsupportedKeys are JSON Schema keywords that Anthropic's strict tool +
// structured-output validator (and OpenAI's strict Responses format) reject with
// a 400. The Python and TypeScript SDKs strip these automatically before sending
// and re-validate them client-side; the Go SDK sends the schema verbatim, so a
// schema containing any of them makes every turn fail as provider_unavailable
// ("For 'array' type, property 'maxItems' is not supported"). We strip them from
// the wire copy here.
//
// Only value/length/count *constraints* are removed. The structural keywords that
// make these schemas closed — type, enum, const, anyOf, properties, required,
// items, additionalProperties:false — are preserved, so the "closed schema"
// property the design depends on is intact. The stripped bounds were advisory to
// the model anyway: ParseEnvelope, the MCP tool boundary, and the draft validator
// re-enforce every one of them downstream, so nothing is lost on the wire.
var strictUnsupportedKeys = map[string]bool{
	"minLength":        true,
	"maxLength":        true,
	"pattern":          true,
	"format":           true,
	"minItems":         true,
	"maxItems":         true,
	"uniqueItems":      true,
	"minimum":          true,
	"maximum":          true,
	"exclusiveMinimum": true,
	"exclusiveMaximum": true,
	"multipleOf":       true,
	"minProperties":    true,
	"maxProperties":    true,
	"default":          true,
}

// strictSchema deep-copies a JSON Schema value, dropping every unsupported
// constraint keyword at any depth. The input is never mutated.
func strictSchema(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(typed))
		for key, val := range typed {
			if strictUnsupportedKeys[key] {
				continue
			}
			out[key] = strictSchema(val)
		}
		return out
	case []any:
		out := make([]any, len(typed))
		for i, elem := range typed {
			out[i] = strictSchema(elem)
		}
		return out
	default:
		return value
	}
}

// strictSchemaMap is strictSchema for a top-level object schema.
func strictSchemaMap(schema map[string]any) map[string]any {
	sanitized, _ := strictSchema(schema).(map[string]any)
	return sanitized
}
