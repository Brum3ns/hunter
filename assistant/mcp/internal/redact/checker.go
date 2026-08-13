package redact

import (
	"bytes"
	"errors"
	"regexp"
)

var (
	ErrUnsafeContent = errors.New("unsafe response content")
	ErrTooLarge      = errors.New("response exceeds size limit")
)

var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bbearer\s+[a-z0-9._~+/=-]{4,}`),
	regexp.MustCompile(`(?i)\b(?:authorization|proxy-authorization)\s*:\s*(?:bearer|basic)\s+[a-z0-9._~+/=-]{4,}`),
	regexp.MustCompile(`(?i)\b(?:cookie|set-cookie)\s*:\s*[^\s=;]+=[^\s;]{4,}`),
	regexp.MustCompile(`(?i)\b(?:x-api-key|api-key|x-auth-token|x-access-token)\s*:\s*[a-z0-9._~+/=-]{4,}`),
	regexp.MustCompile(`(?i)-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)https?://[^\s/@:]+:[^\s/@]+@`),
	regexp.MustCompile(`(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|auth[_-]?token|session[_-]?token|private[_-]?token|token|password|passwd|secret(?:[_-]?key)?)\b\s*[:=]\s*["']?[^\s"']{4,}`),
	regexp.MustCompile(`(?i)"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|client[_-]?secret|auth[_-]?token|session[_-]?token|private[_-]?token|token|password|passwd|secret(?:[_-]?key)?)"\s*:\s*"[^"\s]{4,}"`),
	regexp.MustCompile(`\b(?:AKIA|ASIA)[A-Z0-9]{16}\b`),
	regexp.MustCompile(`(?i)\$ANSIBLE_VAULT;`),
}

type Checker struct {
	maxBytes int
}

func NewChecker(maxBytes int) *Checker {
	return &Checker{maxBytes: maxBytes}
}

func (checker *Checker) Check(body []byte) error {
	if len(body) > checker.maxBytes {
		return ErrTooLarge
	}
	// Rails uses this literal for values it has already scrubbed. Replacing it
	// only in the checker copy lets the JSON-key patterns reject real values
	// without rejecting the reviewed redaction marker itself.
	scan := bytes.ReplaceAll(body, []byte(`"[REDACTED]"`), []byte("null"))
	for _, pattern := range secretPatterns {
		if pattern.Match(scan) {
			return ErrUnsafeContent
		}
	}
	return nil
}
