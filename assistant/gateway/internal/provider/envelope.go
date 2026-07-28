package provider

import (
	"bytes"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

var ErrInvalidEnvelope = errors.New("invalid provider envelope")

var validationCorrelationPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
var contentDigestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)

type Envelope struct {
	Kind               string
	Body               string
	ArtifactType       string
	Name               string
	Content            string
	ValidationCallID   string
	ValidationStatus   string
	ValidationVersion  string
	ValidationCodes    []string
	ValidationMessages []string
}

type ValidationEvidence struct {
	Tool   string
	Result []byte
}

type providerEnvelope struct {
	Kind             string  `json:"kind"`
	Body             *string `json:"body"`
	ArtifactType     *string `json:"artifact_type"`
	Name             *string `json:"name"`
	Content          *string `json:"content"`
	ValidationCallID *string `json:"validation_call_id"`
}

type draftEnvelope struct {
	Kind             string `json:"kind"`
	ArtifactType     string `json:"artifact_type"`
	Name             string `json:"name"`
	Content          string `json:"content"`
	ValidationCallID string `json:"validation_call_id"`
}

type validationResponse struct {
	Result struct {
		CorrelationID string `json:"correlation_id"`
		Validation    struct {
			ID            *string         `json:"id"`
			ArtifactType  string          `json:"artifact_type"`
			Status        string          `json:"status"`
			Valid         bool            `json:"valid"`
			Version       string          `json:"version"`
			Normalized    json.RawMessage `json:"normalized"`
			ContentDigest *string         `json:"content_digest"`
			Details       struct {
				Codes    []string `json:"codes"`
				Messages []string `json:"messages"`
			} `json:"details"`
		} `json:"validation"`
	} `json:"result"`
}

func ParseEnvelope(payload []byte, evidence map[string]ValidationEvidence) (Envelope, error) {
	var value providerEnvelope
	if decodeClosed(payload, &value) != nil || !hasEveryEnvelopeField(payload) {
		return Envelope{}, ErrInvalidEnvelope
	}

	switch value.Kind {
	case "assistant_message":
		if value.Body == nil || *value.Body == "" || len(*value.Body) > 64<<10 || unsafeString(*value.Body) ||
			value.ArtifactType != nil || value.Name != nil || value.Content != nil || value.ValidationCallID != nil {
			return Envelope{}, ErrInvalidEnvelope
		}
		return Envelope{Kind: value.Kind, Body: *value.Body}, nil
	case "draft":
		if value.Body != nil || value.ArtifactType == nil || value.Name == nil || value.Content == nil || value.ValidationCallID == nil {
			return Envelope{}, ErrInvalidEnvelope
		}
		draft := draftEnvelope{
			Kind: value.Kind, ArtifactType: *value.ArtifactType, Name: *value.Name,
			Content: *value.Content, ValidationCallID: *value.ValidationCallID,
		}
		if !validDraft(draft) {
			return Envelope{}, ErrInvalidEnvelope
		}
		proof, ok := evidence[draft.ValidationCallID]
		expectedTool := map[string]string{
			"whiterabbit_template": "validate_whiterabbit_draft",
			"ansible_playbook":     "get_validation_result",
		}[draft.ArtifactType]
		if !ok || proof.Tool != expectedTool {
			return Envelope{}, ErrInvalidEnvelope
		}
		validation, err := parseValidation(proof.Result)
		if err != nil {
			return Envelope{}, err
		}
		validated := validation.Result.Validation
		if validated.ArtifactType != draft.ArtifactType || validated.Status == "pending" || validated.Status == "failed" ||
			validated.ContentDigest == nil || !contentDigestPattern.MatchString(*validated.ContentDigest) ||
			!contentMatchesDigest(draft.Content, *validated.ContentDigest) {
			return Envelope{}, ErrInvalidEnvelope
		}
		if draft.ArtifactType == "whiterabbit_template" && validated.ID != nil {
			return Envelope{}, ErrInvalidEnvelope
		}
		if draft.ArtifactType == "ansible_playbook" &&
			(validated.ID == nil || !validationCorrelationPattern.MatchString(*validated.ID)) {
			return Envelope{}, ErrInvalidEnvelope
		}
		return Envelope{
			Kind: draft.Kind, ArtifactType: draft.ArtifactType, Name: draft.Name,
			Content: draft.Content, ValidationCallID: draft.ValidationCallID,
			ValidationStatus:   validation.Result.Validation.Status,
			ValidationVersion:  validation.Result.Validation.Version,
			ValidationCodes:    validation.Result.Validation.Details.Codes,
			ValidationMessages: validation.Result.Validation.Details.Messages,
		}, nil
	default:
		return Envelope{}, ErrInvalidEnvelope
	}
}

func contentMatchesDigest(content, expected string) bool {
	digest := sha256.Sum256([]byte(content))
	actual := []byte(fmt.Sprintf("%x", digest))
	return subtle.ConstantTimeCompare(actual, []byte(expected)) == 1
}

func hasEveryEnvelopeField(payload []byte) bool {
	var fields map[string]json.RawMessage
	if json.Unmarshal(payload, &fields) != nil || len(fields) != 6 {
		return false
	}
	for _, name := range []string{"kind", "body", "artifact_type", "name", "content", "validation_call_id"} {
		if _, present := fields[name]; !present {
			return false
		}
	}
	return true
}

func decodeClosed(payload []byte, destination any) error {
	if !utf8.Valid(payload) {
		return ErrInvalidEnvelope
	}

	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalidEnvelope
	}
	return nil
}

func validDraft(value draftEnvelope) bool {
	return (value.ArtifactType == "whiterabbit_template" || value.ArtifactType == "ansible_playbook") &&
		value.Name != "" && len(value.Name) <= 200 && value.Content != "" && len(value.Content) <= 256<<10 &&
		value.ValidationCallID != "" && len(value.ValidationCallID) <= 255 &&
		!unsafeString(value.Name) && !unsafeString(value.Content) && !unsafeString(value.ValidationCallID)
}

func parseValidation(payload []byte) (validationResponse, error) {
	var response validationResponse
	if len(payload) == 0 || len(payload) > 64<<10 || decodeClosed(payload, &response) != nil {
		return validationResponse{}, ErrInvalidEnvelope
	}
	validation := response.Result.Validation
	if !validationCorrelationPattern.MatchString(response.Result.CorrelationID) || !slicesContains([]string{"pending", "valid", "invalid", "failed"}, validation.Status) || validation.Version == "" || len(validation.Version) > 64 || len(validation.Details.Codes) > 50 || len(validation.Details.Messages) > 50 {
		return validationResponse{}, ErrInvalidEnvelope
	}
	if validation.Valid != (validation.Status == "valid") || len(validation.Normalized) == 0 || !json.Valid(validation.Normalized) ||
		(validation.Valid && bytes.Equal(bytes.TrimSpace(validation.Normalized), []byte("null"))) {
		return validationResponse{}, ErrInvalidEnvelope
	}
	for _, code := range validation.Details.Codes {
		if code == "" || len(code) > 100 || unsafeString(code) {
			return validationResponse{}, ErrInvalidEnvelope
		}
	}
	for _, message := range validation.Details.Messages {
		if len(message) > 500 || unsafeString(message) {
			return validationResponse{}, ErrInvalidEnvelope
		}
	}
	return response, nil
}

func unsafeString(value string) bool {
	if !utf8.ValidString(value) || strings.Contains(value, "\u2028") || strings.Contains(value, "\u2029") {
		return true
	}
	for _, character := range value {
		if unicode.IsControl(character) && character != '\n' && character != '\t' && character != '\r' {
			return true
		}
	}
	return false
}

func slicesContains(values []string, candidate string) bool {
	for _, value := range values {
		if value == candidate {
			return true
		}
	}
	return false
}

func OutputSchema() map[string]any {
	return map[string]any{
		"type":                 "object",
		"additionalProperties": false,
		"required":             []string{"kind", "body", "artifact_type", "name", "content", "validation_call_id"},
		"properties": map[string]any{
			"kind": described(`"assistant_message" for a normal chat reply; "draft" only when returning a drafted Whiterabbit template or Ansible playbook.`,
				map[string]any{"type": "string", "enum": []string{"assistant_message", "draft"}}),
			"body": described(`Your chat reply text. When kind is "assistant_message" this MUST be a non-empty string holding your entire reply. When kind is "draft" this MUST be null.`,
				nullableSchema(map[string]any{"type": "string", "minLength": 1, "maxLength": 65536})),
			"artifact_type": described(`The drafted artifact's type. Set only when kind is "draft"; MUST be null when kind is "assistant_message".`,
				nullableSchema(map[string]any{"type": "string", "enum": []string{"whiterabbit_template", "ansible_playbook"}})),
			"name": described(`The drafted artifact's name. Set only when kind is "draft"; MUST be null when kind is "assistant_message".`,
				nullableSchema(map[string]any{"type": "string", "minLength": 1, "maxLength": 200})),
			"content": described(`The full text of the drafted artifact. Set only when kind is "draft"; MUST be null when kind is "assistant_message" — never put your chat reply here, that goes in "body".`,
				nullableSchema(map[string]any{"type": "string", "minLength": 1, "maxLength": 262144})),
			"validation_call_id": described(`Set only when kind is "draft"; MUST be null when kind is "assistant_message". Copy VERBATIM the id of your tool call that validated this draft — it begins with "toolu_". For an ansible_playbook draft, use the id of your get_validation_result call; for a whiterabbit_template draft, use the id of your validate_whiterabbit_draft call. Do not invent an id and do not use the validation's own id.`,
				nullableSchema(map[string]any{"type": "string", "minLength": 1, "maxLength": 255})),
		},
	}
}

// described attaches a JSON Schema description to a property so the model knows
// which field to fill. Structured-output models rely on these; with none, an
// assistant_message reply was being placed in "content" with "body" left null,
// failing envelope validation. description is a supported strict-schema keyword
// (not stripped by strictSchema).
func described(description string, schema map[string]any) map[string]any {
	schema["description"] = description
	return schema
}

func nullableSchema(schema map[string]any) map[string]any {
	return map[string]any{"anyOf": []any{schema, map[string]any{"type": "null"}}}
}
