package provider

import (
	"reflect"
	"strings"
	"testing"
)

// findUnsupported walks a JSON Schema and returns the first unsupported keyword
// it finds at any depth, or "" if the schema is strict-clean.
func findUnsupported(value any) string {
	switch typed := value.(type) {
	case map[string]any:
		for key, val := range typed {
			if strictUnsupportedKeys[key] {
				return key
			}
			if found := findUnsupported(val); found != "" {
				return found
			}
		}
	case []any:
		for _, elem := range typed {
			if found := findUnsupported(elem); found != "" {
				return found
			}
		}
	}
	return ""
}

func hasKey(schema map[string]any, key string) bool {
	_, ok := schema[key]
	return ok
}

// Anthropic's strict validator rejects constraint keywords (maxItems, minLength,
// pattern, ...); an un-sanitized schema 400s and every turn fails as
// provider_unavailable. Every schema that reaches a provider must be clean.
func TestOutputSchemaIsStrictCleanOnTheWire(t *testing.T) {
	if found := findUnsupported(strictSchemaMap(OutputSchema())); found != "" {
		t.Fatalf("sanitized OutputSchema still carries unsupported keyword %q", found)
	}
	// The raw schema is expected to carry them — this proves the sanitizer is
	// doing real work rather than the schema happening to be clean already.
	if found := findUnsupported(OutputSchema()); found == "" {
		t.Fatal("OutputSchema has no constraints to strip; this test is asserting nothing")
	}
}

func TestEveryToolSchemaIsStrictCleanOnTheWire(t *testing.T) {
	strippedSomething := false
	for _, definition := range fixedTools() {
		if findUnsupported(definition.Schema) != "" {
			strippedSomething = true
		}
		sanitized := strictSchemaMap(definition.Schema)
		if found := findUnsupported(sanitized); found != "" {
			t.Fatalf("tool %q still carries unsupported keyword %q after sanitizing", definition.Name, found)
		}
		// Closedness must survive sanitizing: additionalProperties:false stays.
		if av, ok := sanitized["additionalProperties"]; !ok || av != false {
			t.Fatalf("tool %q lost additionalProperties:false", definition.Name)
		}
	}
	if !strippedSomething {
		t.Fatal("no tool schema had constraints to strip; this test is asserting nothing")
	}
}

// Structural keywords must be preserved — enum and required are what make the
// schema a *closed* contract, not just the absence of constraints.
func TestSanitizerPreservesStructuralKeywords(t *testing.T) {
	out := strictSchemaMap(OutputSchema())
	if !hasKey(out, "required") || !hasKey(out, "properties") {
		t.Fatal("sanitizer dropped required/properties from OutputSchema")
	}
	kind, _ := out["properties"].(map[string]any)["kind"].(map[string]any)
	if _, ok := kind["enum"]; !ok {
		t.Fatal("sanitizer dropped the enum on OutputSchema.kind")
	}
}

// The canonical schemas are shared; sanitizing for the wire must not mutate them.
func TestSanitizerDoesNotMutateInput(t *testing.T) {
	before := OutputSchema()
	snapshot := OutputSchema() // independent copy from the constructor
	_ = strictSchemaMap(before)
	if !reflect.DeepEqual(before, snapshot) {
		t.Fatal("strictSchemaMap mutated its input schema")
	}
}

// Guards the envelope-field-guidance fix: without descriptions the model put
// assistant_message replies in "content" with "body" null, failing validation.
// The descriptions must also survive the wire sanitizer (description is not a
// stripped keyword) or the guidance never reaches the provider.
func TestOutputSchemaKeepsFieldDescriptionsOnTheWire(t *testing.T) {
	wire := strictSchemaMap(OutputSchema())
	props, ok := wire["properties"].(map[string]any)
	if !ok {
		t.Fatal("wire schema has no properties")
	}
	for _, field := range []string{"kind", "body", "content"} {
		p, _ := props[field].(map[string]any)
		desc, _ := p["description"].(string)
		if desc == "" {
			t.Fatalf("wire schema field %q lost its description (guidance stripped)", field)
		}
	}
	// The body/content distinction must be spelled out — that's the actual fix.
	body, _ := props["body"].(map[string]any)["description"].(string)
	content, _ := props["content"].(map[string]any)["description"].(string)
	if !strings.Contains(body, "assistant_message") || !strings.Contains(content, "draft") {
		t.Fatalf("body/content descriptions do not distinguish the two kinds: body=%q content=%q", body, content)
	}
}
