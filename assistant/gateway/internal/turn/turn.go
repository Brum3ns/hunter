package turn

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"hunter.local/assistant/gateway/internal/config"
	mcpclient "hunter.local/assistant/gateway/internal/mcp"
	"hunter.local/assistant/gateway/internal/prompt"
	"hunter.local/assistant/gateway/internal/provider"
)

const (
	maxJobBytes     = 128 << 10
	maxTurnDuration = 5 * time.Minute
)

var (
	ErrInvalidJob = errors.New("invalid turn job")
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

type ProviderProfile struct {
	ProfileID        int64  `json:"profile_id"`
	CatalogSlug      string `json:"catalog_slug"`
	Provider         string `json:"provider"`
	Model            string `json:"model"`
	SecretRef        string `json:"secret_ref"`
	InputLimit       int    `json:"input_limit"`
	OutputLimit      int    `json:"output_limit"`
	ToolCallLimit    int    `json:"tool_call_limit"`
	RetentionPosture string `json:"retention_posture"`
	ReviewedAt       string `json:"reviewed_at"`
}

type ContextReference struct {
	Type              string `json:"type"`
	ID                string `json:"id"`
	Label             string `json:"label"`
	SerializerVersion string `json:"serializer_version"`
}

type TurnJob struct {
	SchemaVersion     int                `json:"schema_version"`
	CorrelationID     string             `json:"correlation_id"`
	TurnID            int64              `json:"turn_id"`
	ConversationID    int64              `json:"conversation_id"`
	UserID            int64              `json:"user_id"`
	ProviderProfile   ProviderProfile    `json:"provider_profile"`
	UserMessage       string             `json:"user_message"`
	ContextReferences []ContextReference `json:"context_references"`
	TurnGrant         string             `json:"turn_grant"`
	ExpiresAt         string             `json:"expires_at"`
}

type AssistantEvent struct {
	SchemaVersion     int    `json:"schema_version"`
	EventID           string `json:"event_id"`
	CorrelationID     string `json:"correlation_id"`
	TurnID            int64  `json:"turn_id"`
	ProviderProfileID int64  `json:"provider_profile_id"`
	Kind              string `json:"kind"`
	Data              any    `json:"data"`
}

type Generator interface {
	Handle(context.Context, string, provider.Request, provider.ToolExecutor) provider.HandleEvent
}

type ToolSession interface {
	provider.ToolExecutor
	Close() error
}

type MCPConnect func(context.Context, string) (ToolSession, error)

type Processor struct {
	Gateway Generator
	Connect MCPConnect
	Now     func() time.Time
}

func DecodeTurnJob(payload []byte, now time.Time) (TurnJob, error) {
	var job TurnJob
	if len(payload) == 0 || len(payload) > maxJobBytes || decodeClosed(payload, &job) != nil {
		return TurnJob{}, ErrInvalidJob
	}
	expiresAt, err := time.Parse(time.RFC3339, job.ExpiresAt)
	if err != nil || !expiresAt.After(now) || expiresAt.After(now.Add(maxTurnDuration+5*time.Second)) {
		return TurnJob{}, ErrInvalidJob
	}
	if job.SchemaVersion != 1 || !uuidPattern.MatchString(job.CorrelationID) || job.TurnID < 1 || job.ConversationID < 1 || job.UserID < 1 || len(job.UserMessage) == 0 || len(job.UserMessage) > 64<<10 || unsafeText(job.UserMessage) || len(job.TurnGrant) < 32 || len(job.TurnGrant) > 256 || strings.ContainsAny(job.TurnGrant, "\x00\r\n\t ") || len(job.ContextReferences) > 10 {
		return TurnJob{}, ErrInvalidJob
	}
	profile := job.ProviderProfile
	if profile.ProfileID < 1 || profile.CatalogSlug != profile.SecretRef || config.ValidateProfile(config.Profile{Provider: profile.Provider, Model: profile.Model, SecretRef: profile.SecretRef}) != nil || profile.InputLimit < 1 || profile.InputLimit > 32768 || profile.OutputLimit < 1 || profile.OutputLimit > 8192 || profile.ToolCallLimit < 1 || profile.ToolCallLimit > 8 || !slices.Contains([]string{"standard", "zero_data_retention"}, profile.RetentionPosture) {
		return TurnJob{}, ErrInvalidJob
	}
	reviewedAt, err := time.Parse(time.RFC3339, profile.ReviewedAt)
	if err != nil || reviewedAt.After(now.Add(5*time.Minute)) {
		return TurnJob{}, ErrInvalidJob
	}
	for _, reference := range job.ContextReferences {
		if !slices.Contains([]string{"program", "target", "cve", "vulnerability", "whiterabbit_template", "ansible_playbook"}, reference.Type) || reference.ID == "" || len(reference.ID) > 255 || reference.Label == "" || len(reference.Label) > 255 || reference.SerializerVersion != "v1" || unsafeText(reference.ID) || unsafeText(reference.Label) {
			return TurnJob{}, ErrInvalidJob
		}
	}
	return job, nil
}

func (processor *Processor) Process(parent context.Context, job TurnJob) []AssistantEvent {
	now := time.Now
	if processor.Now != nil {
		now = processor.Now
	}
	expiresAt, _ := time.Parse(time.RFC3339, job.ExpiresAt)
	deadline := now().Add(maxTurnDuration)
	if expiresAt.Before(deadline) {
		deadline = expiresAt
	}
	ctx, cancel := context.WithDeadline(parent, deadline)
	defer cancel()
	events := make([]AssistantEvent, 0, 2)

	references := make([]prompt.ContextReference, 0, len(job.ContextReferences))
	for _, reference := range job.ContextReferences {
		references = append(references, prompt.ContextReference{Type: reference.Type, ID: reference.ID, Label: reference.Label})
	}
	built, err := prompt.Build(job.UserMessage, references)
	if err != nil {
		return append(events, errorEvent(job, "invalid_prompt"))
	}
	session, err := processor.Connect(ctx, job.TurnGrant)
	if err != nil {
		return append(events, errorEvent(job, "mcp_unavailable"))
	}
	defer session.Close()

	handled := processor.Gateway.Handle(ctx, job.ProviderProfile.Provider, provider.Request{
		Model: job.ProviderProfile.Model, System: built.System, UserContent: built.UserContent,
		MaxOutputTokens: job.ProviderProfile.OutputLimit, ToolCallLimit: job.ProviderProfile.ToolCallLimit,
	}, session)
	if handled.Code != "" || handled.Result == nil {
		code := handled.Code
		if code == "" {
			code = "provider_unavailable"
		}
		return append(events, errorEvent(job, code))
	}
	result := handled.Result
	if result.Usage.InputTokens > job.ProviderProfile.InputLimit || result.Usage.OutputTokens > job.ProviderProfile.OutputLimit || result.ToolCallCount > job.ProviderProfile.ToolCallLimit {
		return append(events, errorEvent(job, "provider_limit_exceeded"))
	}

	switch result.Envelope.Kind {
	case "assistant_message":
		events = append(events, newEvent(job, "assistant_message", map[string]any{"body": result.Envelope.Body}))
	case "draft":
		events = append(events, newEvent(job, "draft", map[string]any{
			"artifact_type":      result.Envelope.ArtifactType,
			"name":               result.Envelope.Name,
			"content":            result.Envelope.Content,
			"validation_details": map[string]any{"codes": result.Envelope.ValidationCodes, "messages": result.Envelope.ValidationMessages},
			"validation_status":  result.Envelope.ValidationStatus,
			"validation_version": result.Envelope.ValidationVersion,
		}))
	default:
		return append(events, errorEvent(job, "invalid_provider_output"))
	}
	events = append(events, newEvent(job, "completed", map[string]any{
		"input_tokens": result.Usage.InputTokens, "output_tokens": result.Usage.OutputTokens,
		"tool_call_count": result.ToolCallCount,
	}))
	return events
}

func newEvent(job TurnJob, kind string, data any) AssistantEvent {
	return AssistantEvent{
		SchemaVersion: 1, EventID: newUUID(), CorrelationID: job.CorrelationID,
		TurnID: job.TurnID, ProviderProfileID: job.ProviderProfile.ProfileID,
		Kind: kind, Data: data,
	}
}

func errorEvent(job TurnJob, code string) AssistantEvent {
	return newEvent(job, "error", map[string]any{"code": code})
}

func newUUID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		panic("secure random source unavailable")
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(value[:])
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32]
}

func decodeClosed(payload []byte, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalidJob
	}
	return nil
}

func unsafeText(value string) bool {
	if !utf8.ValidString(value) {
		return true
	}
	for _, character := range value {
		if unicode.IsControl(character) && character != '\n' && character != '\r' && character != '\t' {
			return true
		}
	}
	return false
}

func ConnectMCP(client *mcpclient.Client) MCPConnect {
	return func(ctx context.Context, grant string) (ToolSession, error) {
		return client.Connect(ctx, grant)
	}
}
