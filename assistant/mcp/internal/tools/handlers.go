package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"hunter.local/assistant/mcp/internal/hunter"
	"hunter.local/assistant/mcp/internal/limits"
	"hunter.local/assistant/mcp/internal/redact"
)

var (
	ErrUnknownTool      = errors.New("unknown tool")
	ErrInvalidInput     = errors.New("invalid tool input")
	ErrToolDenied       = errors.New("tool not granted")
	ErrResourceDenied   = errors.New("resource not granted")
	ErrGrantExpired     = errors.New("turn grant expired")
	ErrResponseRejected = errors.New("tool response rejected")
)

var (
	safeID        = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$`)
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	codePattern   = regexp.MustCompile(`^[a-z0-9_.-]{1,100}$`)
	digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
)

var resourceTypes = []string{
	"program", "target", "cve", "vulnerability", "whiterabbit_template", "ansible_playbook",
}

type ExactResourceInput struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

type artifactInput struct {
	ArtifactType string `json:"artifact_type"`
}

type validationResultInput struct {
	ID string `json:"id"`
}

type whiterabbitInput struct {
	Draft whiterabbitDraft `json:"draft"`
}

type whiterabbitDraft struct {
	Name        string               `json:"name"`
	Kind        string               `json:"kind,omitempty"`
	Description string               `json:"description,omitempty"`
	Commands    []whiterabbitCommand `json:"commands"`
}

type whiterabbitCommand struct {
	Command  string   `json:"command"`
	Args     []string `json:"args"`
	Operator string   `json:"operator,omitempty"`
}

type ansibleInput struct {
	Draft ansibleDraft `json:"draft"`
}

type ansibleDraft struct {
	Name   string `json:"name"`
	Source string `json:"source"`
}

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

type Handler struct {
	client  hunter.Client
	checker *redact.Checker
	budget  *limits.Budget
}

func NewHandler(client hunter.Client, checker *redact.Checker) *Handler {
	if checker == nil {
		checker = redact.NewChecker(64 << 10)
	}
	return &Handler{client: client, checker: checker, budget: limits.NewBudget(8)}
}

func DecodeExactResource(input []byte) (ExactResourceInput, error) {
	var decoded ExactResourceInput
	if err := decodeClosed(input, &decoded); err != nil || !slices.Contains(resourceTypes, decoded.Type) || !safeID.MatchString(decoded.ID) {
		return ExactResourceInput{}, ErrInvalidInput
	}
	return decoded, nil
}

func (handler *Handler) Call(ctx context.Context, rawGrant, tool string, arguments []byte) ([]byte, error) {
	if rawGrant == "" {
		return nil, ErrToolDenied
	}
	input, resource, err := decodeInput(tool, arguments)
	if err != nil {
		return nil, err
	}

	grant, err := handler.client.Introspect(ctx, rawGrant)
	if err != nil {
		return nil, ErrToolDenied
	}
	if !grant.ExpiresAt.After(time.Now()) {
		return nil, ErrGrantExpired
	}
	if !slices.Contains(grant.Tools, tool) {
		return nil, ErrToolDenied
	}
	if resource != nil && !resourceGranted(grant.Resources, *resource) {
		return nil, ErrResourceDenied
	}
	if err := handler.budget.Reserve(rawGrant, grant.CallsRemaining, grant.BytesRemaining); err != nil {
		return nil, ErrToolDenied
	}

	var payload []byte
	switch typed := input.(type) {
	case ExactResourceInput:
		payload, err = handler.client.Get(ctx, rawGrant, tool, typed.Type, typed.ID)
	case artifactInput:
		payload, err = handler.client.Get(ctx, rawGrant, tool, typed.ArtifactType, "")
	case validationResultInput:
		payload, err = handler.client.Get(ctx, rawGrant, tool, "", typed.ID)
	case whiterabbitInput, ansibleInput:
		payload, err = handler.client.Post(ctx, rawGrant, tool, typed)
	default:
		return nil, ErrUnknownTool
	}
	if err != nil {
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return nil, err
		}
		return nil, ErrResponseRejected
	}
	if err := handler.checker.Check(payload); err != nil || validateOutput(tool, payload) != nil {
		return nil, ErrResponseRejected
	}
	return payload, nil
}

func decodeInput(tool string, arguments []byte) (any, *hunter.Resource, error) {
	switch tool {
	case "get_selected_context", "get_artifact_example":
		input, err := DecodeExactResource(arguments)
		if err != nil {
			return nil, nil, err
		}
		if tool == "get_artifact_example" && input.Type != "whiterabbit_template" && input.Type != "ansible_playbook" {
			return nil, nil, ErrInvalidInput
		}
		return input, &hunter.Resource{Type: input.Type, ID: input.ID}, nil
	case "get_authoring_policy":
		var input artifactInput
		if err := decodeClosed(arguments, &input); err != nil || !validArtifactType(input.ArtifactType) {
			return nil, nil, ErrInvalidInput
		}
		return input, nil, nil
	case "get_validation_result":
		var input validationResultInput
		if err := decodeClosed(arguments, &input); err != nil || !safeID.MatchString(input.ID) {
			return nil, nil, ErrInvalidInput
		}
		return input, nil, nil
	case "validate_whiterabbit_draft":
		var input whiterabbitInput
		if err := decodeClosed(arguments, &input); err != nil || validateWhiterabbit(input) != nil {
			return nil, nil, ErrInvalidInput
		}
		return input, nil, nil
	case "validate_ansible_draft":
		var input ansibleInput
		if err := decodeClosed(arguments, &input); err != nil || validateAnsible(input) != nil {
			return nil, nil, ErrInvalidInput
		}
		return input, nil, nil
	default:
		return nil, nil, ErrUnknownTool
	}
}

func decodeClosed(input []byte, destination any) error {
	if len(input) == 0 || len(input) > 64<<10 || !utf8.Valid(input) {
		return ErrInvalidInput
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrInvalidInput
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalidInput
	}
	return nil
}

func validateWhiterabbit(input whiterabbitInput) error {
	if strings.TrimSpace(input.Draft.Name) == "" || len(input.Draft.Name) > 200 || len(input.Draft.Kind) > 40 || len(input.Draft.Description) > 4000 || len(input.Draft.Commands) == 0 || len(input.Draft.Commands) > 50 {
		return ErrInvalidInput
	}
	for _, command := range input.Draft.Commands {
		if strings.TrimSpace(command.Command) == "" || len(command.Command) > 255 || len(command.Operator) > 4 || len(command.Args) > 200 {
			return ErrInvalidInput
		}
		for _, argument := range command.Args {
			if len(argument) > 4096 {
				return ErrInvalidInput
			}
		}
	}
	return nil
}

func validateAnsible(input ansibleInput) error {
	if strings.TrimSpace(input.Draft.Name) == "" || len(input.Draft.Name) > 200 || strings.TrimSpace(input.Draft.Source) == "" || len(input.Draft.Source) > 64<<10 {
		return ErrInvalidInput
	}
	return nil
}

func validArtifactType(value string) bool {
	return value == "whiterabbit_template" || value == "ansible_playbook"
}

func resourceGranted(resources []hunter.Resource, requested hunter.Resource) bool {
	return slices.Contains(resources, requested)
}

func validateOutput(tool string, payload []byte) error {
	if !utf8.Valid(payload) {
		return ErrResponseRejected
	}
	var root map[string]json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(payload))
	if err := decoder.Decode(&root); err != nil || decoder.Decode(&struct{}{}) != io.EOF {
		return ErrResponseRejected
	}
	allowed := map[string][]string{
		"get_selected_context":       {"correlation_id", "context"},
		"get_artifact_example":       {"correlation_id", "artifact"},
		"get_authoring_policy":       {"correlation_id", "policy"},
		"get_validation_result":      {"correlation_id", "validation"},
		"validate_whiterabbit_draft": {"correlation_id", "validation"},
		"validate_ansible_draft":     {"correlation_id", "validation"},
	}[tool]
	if allowed == nil {
		return ErrUnknownTool
	}
	for key := range root {
		if !slices.Contains(allowed, key) {
			return ErrResponseRejected
		}
	}
	for _, required := range allowed {
		if _, ok := root[required]; !ok {
			return ErrResponseRejected
		}
	}
	if slices.Contains([]string{"get_validation_result", "validate_whiterabbit_draft", "validate_ansible_draft"}, tool) {
		return validateValidationOutput(tool, root)
	}
	return nil
}

func validateValidationOutput(tool string, root map[string]json.RawMessage) error {
	var correlationID string
	if json.Unmarshal(root["correlation_id"], &correlationID) != nil || !uuidPattern.MatchString(correlationID) {
		return ErrResponseRejected
	}

	var fields map[string]json.RawMessage
	if json.Unmarshal(root["validation"], &fields) != nil || !exactKeys(fields, []string{
		"id", "artifact_type", "status", "valid", "version", "normalized", "content_digest", "details",
	}) {
		return ErrResponseRejected
	}
	var detailsFields map[string]json.RawMessage
	if json.Unmarshal(fields["details"], &detailsFields) != nil || !exactKeys(detailsFields, []string{"codes", "messages"}) {
		return ErrResponseRejected
	}

	var validation validationOutput
	if json.Unmarshal(root["validation"], &validation) != nil || validation.Details.Codes == nil || validation.Details.Messages == nil || len(validation.Details.Codes) != len(validation.Details.Messages) || len(validation.Details.Codes) > 50 {
		return ErrResponseRejected
	}
	if validation.ID != nil && !uuidPattern.MatchString(*validation.ID) {
		return ErrResponseRejected
	}
	if !codePattern.MatchString(validation.Version) || validation.Valid != (validation.Status == "valid") {
		return ErrResponseRejected
	}
	for index, code := range validation.Details.Codes {
		message := validation.Details.Messages[index]
		if !codePattern.MatchString(code) || len(message) == 0 || len(message) > 500 || strings.ContainsAny(message, "\x00\r\n") {
			return ErrResponseRejected
		}
	}
	if validation.ContentDigest != nil && !digestPattern.MatchString(*validation.ContentDigest) {
		return ErrResponseRejected
	}

	expectedArtifact := "ansible_playbook"
	allowedStatuses := []string{"pending", "valid", "invalid", "failed", "expired"}
	if tool == "validate_whiterabbit_draft" {
		expectedArtifact = "whiterabbit_template"
		allowedStatuses = []string{"valid", "invalid"}
	} else if tool == "validate_ansible_draft" {
		allowedStatuses = []string{"pending", "invalid"}
	}
	if validation.ArtifactType != expectedArtifact || !slices.Contains(allowedStatuses, validation.Status) {
		return ErrResponseRejected
	}
	if (validation.Status == "pending" || validation.Status == "valid") != (len(validation.Details.Codes) == 0) {
		return ErrResponseRejected
	}
	if tool == "get_validation_result" && validation.ID == nil {
		return ErrResponseRejected
	}
	if tool == "validate_whiterabbit_draft" && validation.ID != nil {
		return ErrResponseRejected
	}

	normalizedIsNull := bytes.Equal(bytes.TrimSpace(validation.Normalized), []byte("null"))
	if len(validation.Normalized) == 0 || (normalizedIsNull && validation.ContentDigest != nil) || (!normalizedIsNull && validation.ContentDigest == nil) {
		return ErrResponseRejected
	}
	if normalizedIsNull {
		return nil
	}
	if validation.ArtifactType == "ansible_playbook" {
		var normalized ansibleNormalized
		if decodeRawClosed(validation.Normalized, &normalized) != nil || strings.TrimSpace(normalized.Source) == "" || len(normalized.Source) > 64<<10 || len(normalized.Name) > 200 {
			return ErrResponseRejected
		}
		return nil
	}
	var normalized whiterabbitDraft
	if decodeRawClosed(validation.Normalized, &normalized) != nil || validateWhiterabbit(whiterabbitInput{Draft: normalized}) != nil {
		return ErrResponseRejected
	}
	return nil
}

func exactKeys(fields map[string]json.RawMessage, required []string) bool {
	if len(fields) != len(required) {
		return false
	}
	for _, key := range required {
		if _, ok := fields[key]; !ok {
			return false
		}
	}
	return true
}

func decodeRawClosed(input json.RawMessage, destination any) error {
	if !utf8.Valid(input) {
		return ErrResponseRejected
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrResponseRejected
	}
	return nil
}

func publicError(err error) string {
	switch {
	case errors.Is(err, ErrUnknownTool):
		return "unknown_tool"
	case errors.Is(err, ErrInvalidInput):
		return "invalid_tool_input"
	case errors.Is(err, ErrResourceDenied):
		return "resource_not_granted"
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "tool_call_cancelled"
	case errors.Is(err, ErrToolDenied), errors.Is(err, ErrGrantExpired):
		return "turn_grant_rejected"
	default:
		return "tool_response_rejected"
	}
}
