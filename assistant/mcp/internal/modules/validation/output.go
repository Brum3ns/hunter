package validation

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"hunter.local/assistant/mcp/internal/codec"
)

var errInvalid = codec.ErrInvalid

var errRejected = errors.New("tool response rejected")

var (
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	codePattern   = regexp.MustCompile(`^[a-z0-9_.-]{1,100}$`)
	digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

type validationOutput struct {
	ID            *string           `json:"id"`
	ArtifactType  string            `json:"artifact_type"`
	Status        string            `json:"status"`
	Valid         bool              `json:"valid"`
	Version       string            `json:"version"`
	Normalized    json.RawMessage   `json:"normalized"`
	ContentDigest *string           `json:"content_digest"`
	Details       validationDetails `json:"details"`
}

type validationDetails struct {
	Codes    []string `json:"codes"`
	Messages []string `json:"messages"`
}

type ansibleNormalized struct {
	Name   string `json:"name,omitempty"`
	Source string `json:"source"`
}

// validateOutput enforces the {correlation_id,validation} envelope and the deep,
// closed validation-result shape for one of the three validation tools.
func validateOutput(toolName string, payload []byte) error {
	if !utf8.Valid(payload) {
		return errRejected
	}
	var root map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&root); err != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return errRejected
	}
	if !codec.ExactKeys(root, []string{"correlation_id", "validation"}) {
		return errRejected
	}
	return validateValidationOutput(toolName, root)
}

func validateValidationOutput(toolName string, root map[string]json.RawMessage) error {
	var correlationID string
	if json.Unmarshal(root["correlation_id"], &correlationID) != nil || !uuidPattern.MatchString(correlationID) {
		return errRejected
	}

	var fields map[string]json.RawMessage
	if json.Unmarshal(root["validation"], &fields) != nil || !codec.ExactKeys(fields, []string{
		"id", "artifact_type", "status", "valid", "version", "normalized", "content_digest", "details",
	}) {
		return errRejected
	}
	var detailsFields map[string]json.RawMessage
	if json.Unmarshal(fields["details"], &detailsFields) != nil || !codec.ExactKeys(detailsFields, []string{"codes", "messages"}) {
		return errRejected
	}

	var validation validationOutput
	if json.Unmarshal(root["validation"], &validation) != nil || validation.Details.Codes == nil || validation.Details.Messages == nil || len(validation.Details.Codes) != len(validation.Details.Messages) || len(validation.Details.Codes) > 50 {
		return errRejected
	}
	if validation.ID != nil && !uuidPattern.MatchString(*validation.ID) {
		return errRejected
	}
	if !codePattern.MatchString(validation.Version) || validation.Valid != (validation.Status == "valid") {
		return errRejected
	}
	for index, code := range validation.Details.Codes {
		message := validation.Details.Messages[index]
		if !codePattern.MatchString(code) || len(message) == 0 || len(message) > 500 || strings.ContainsAny(message, "\x00\r\n") {
			return errRejected
		}
	}
	if validation.ContentDigest != nil && !digestPattern.MatchString(*validation.ContentDigest) {
		return errRejected
	}

	expectedArtifact := "ansible_playbook"
	allowedStatuses := []string{"pending", "valid", "invalid", "failed", "expired"}
	if toolName == "validate_whiterabbit_draft" {
		expectedArtifact = "whiterabbit_template"
		allowedStatuses = []string{"valid", "invalid"}
	} else if toolName == "validate_ansible_draft" {
		allowedStatuses = []string{"pending", "invalid"}
	}
	if validation.ArtifactType != expectedArtifact || !slices.Contains(allowedStatuses, validation.Status) {
		return errRejected
	}
	if (validation.Status == "pending" || validation.Status == "valid") != (len(validation.Details.Codes) == 0) {
		return errRejected
	}
	if toolName == "get_validation_result" && validation.ID == nil {
		return errRejected
	}
	if toolName == "validate_whiterabbit_draft" && validation.ID != nil {
		return errRejected
	}

	normalizedIsNull := bytes.Equal(bytes.TrimSpace(validation.Normalized), []byte("null"))
	if len(validation.Normalized) == 0 || (normalizedIsNull && validation.ContentDigest != nil) || (!normalizedIsNull && validation.ContentDigest == nil) {
		return errRejected
	}
	if normalizedIsNull {
		return nil
	}
	if validation.ArtifactType == "ansible_playbook" {
		var normalized ansibleNormalized
		if codec.DecodeRawClosed(validation.Normalized, &normalized) != nil || strings.TrimSpace(normalized.Source) == "" || len(normalized.Source) > 64<<10 || len(normalized.Name) > 200 {
			return errRejected
		}
		return nil
	}
	var normalized whiterabbitDraft
	if codec.DecodeRawClosed(validation.Normalized, &normalized) != nil || validateWhiterabbit(whiterabbitInput{Draft: normalized}) != nil {
		return errRejected
	}
	return nil
}
