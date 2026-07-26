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

	amqp "github.com/rabbitmq/amqp091-go"
	"hunter.local/assistant/validator/internal/check"
)

const (
	validationQueue       = "assistant.validator.requests"
	validationExchange    = "assistant.validation_events"
	validationRoutingKey  = "assistant.rails.validation_events"
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

func Run(ctx context.Context, amqpURL string, processor Processor) error {
	connection, err := amqp.DialConfig(amqpURL, amqp.Config{Heartbeat: 10 * time.Second, Locale: "en_US"})
	if err != nil {
		return errors.New("validator queue connection failed")
	}
	defer connection.Close()
	channel, err := connection.Channel()
	if err != nil {
		return errors.New("validator queue channel failed")
	}
	defer channel.Close()
	if err := channel.Qos(1, 0, false); err != nil {
		return errors.New("validator queue QoS failed")
	}
	if err := channel.Confirm(false); err != nil {
		return errors.New("validator queue confirms unavailable")
	}
	confirmations := channel.NotifyPublish(make(chan amqp.Confirmation, 1))
	deliveries, err := channel.Consume(validationQueue, "hunter-assistant-validator", false, false, false, false, nil)
	if err != nil {
		return errors.New("validator queue consume failed")
	}

	for {
		select {
		case <-ctx.Done():
			return nil
		case delivery, ok := <-deliveries:
			if !ok {
				return errors.New("validator queue closed")
			}
			if delivery.ContentType != "application/json" {
				_ = delivery.Nack(false, false)
				continue
			}
			job, decodeErr := DecodeJob(delivery.Body, time.Now().UTC())
			if decodeErr != nil {
				_ = delivery.Nack(false, false)
				continue
			}
			event := processor.Process(ctx, job)
			if publishEvent(ctx, channel, confirmations, event) == nil {
				_ = delivery.Ack(false)
			} else {
				_ = delivery.Nack(false, true)
			}
		}
	}
}

func publishEvent(ctx context.Context, channel *amqp.Channel, confirmations <-chan amqp.Confirmation, event Event) error {
	payload, err := json.Marshal(event)
	if err != nil {
		return errors.New("validator event encoding failed")
	}
	if err := channel.PublishWithContext(ctx, validationExchange, validationRoutingKey, false, false, amqp.Publishing{
		ContentType:   "application/json",
		DeliveryMode:  amqp.Transient,
		MessageId:     event.EventID,
		CorrelationId: event.CorrelationID,
		Timestamp:     time.Now().UTC(),
		Body:          payload,
	}); err != nil {
		return errors.New("validator event publish failed")
	}
	select {
	case confirmation := <-confirmations:
		if !confirmation.Ack {
			return errors.New("validator event publish rejected")
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(5 * time.Second):
		return errors.New("validator event publish confirmation timed out")
	}
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
