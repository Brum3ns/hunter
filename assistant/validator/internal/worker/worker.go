package worker

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"hunter.local/assistant/validator/internal/check"
)

const (
	maxJobBytes           = 128 << 10
	maxSourceBytes        = 64 << 10
	maxValidationDuration = 5 * time.Minute
)

var (
	ErrInvalidJob = errors.New("invalid validation job")
	uuidPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	codePattern   = regexp.MustCompile(`^[a-z0-9_.-]{1,100}$`)
)

type Job struct {
	SchemaVersion int    `json:"schema_version"`
	ValidationID  string `json:"validation_id"`
	CorrelationID string `json:"correlation_id"`
	TurnID        int64  `json:"turn_id"`
	Source        string `json:"source"`
	ExpiresAt     string `json:"expires_at"`
}

type Event struct {
	SchemaVersion int      `json:"schema_version"`
	EventID       string   `json:"event_id"`
	ValidationID  string   `json:"validation_id"`
	CorrelationID string   `json:"correlation_id"`
	Status        string   `json:"status"`
	Codes         []string `json:"codes"`
}

type Checker interface {
	Check(context.Context, string) check.Result
}

type Processor struct {
	Checker Checker
}

func DecodeJob(payload []byte, now time.Time) (Job, error) {
	var job Job
	if len(payload) == 0 || len(payload) > maxJobBytes || decodeClosed(payload, &job) != nil {
		return Job{}, ErrInvalidJob
	}
	expiresAt, err := time.Parse(time.RFC3339, job.ExpiresAt)
	if err != nil || !expiresAt.After(now) || expiresAt.After(now.Add(maxValidationDuration+5*time.Second)) {
		return Job{}, ErrInvalidJob
	}
	if job.SchemaVersion != 1 || !uuidPattern.MatchString(job.ValidationID) || !uuidPattern.MatchString(job.CorrelationID) || job.TurnID < 1 || len(job.Source) == 0 || len(job.Source) > maxSourceBytes || !utf8.ValidString(job.Source) || strings.IndexByte(job.Source, 0) >= 0 {
		return Job{}, ErrInvalidJob
	}
	return job, nil
}

func (processor Processor) Process(parent context.Context, job Job) Event {
	event := Event{
		SchemaVersion: 1,
		EventID:       newUUID(),
		ValidationID:  job.ValidationID,
		CorrelationID: job.CorrelationID,
		Status:        "failed",
		Codes:         []string{"validator_failed"},
	}
	if processor.Checker == nil {
		return event
	}
	expiresAt, err := time.Parse(time.RFC3339, job.ExpiresAt)
	if err != nil || !expiresAt.After(time.Now()) {
		event.Codes = []string{"validator_timeout"}
		return event
	}
	ctx, cancel := context.WithDeadline(parent, expiresAt)
	defer cancel()
	result := processor.Checker.Check(ctx, job.Source)
	if !validResult(result) {
		return event
	}
	event.Status = result.Status
	event.Codes = append([]string(nil), result.Codes...)
	return event
}

func validResult(result check.Result) bool {
	if result.Status != "valid" && result.Status != "invalid" && result.Status != "failed" {
		return false
	}
	if len(result.Codes) > 50 || (result.Status == "valid" && len(result.Codes) != 0) || (result.Status != "valid" && len(result.Codes) == 0) {
		return false
	}
	for _, code := range result.Codes {
		if !codePattern.MatchString(code) {
			return false
		}
	}
	return true
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
