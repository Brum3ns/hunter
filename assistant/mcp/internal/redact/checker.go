package redact

import (
	"errors"
	"regexp"
)

var (
	ErrUnsafeContent = errors.New("unsafe response content")
	ErrTooLarge      = errors.New("response exceeds size limit")
)

var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`(?i)\bbearer\s+[a-z0-9._~+/=-]{4,}`),
	regexp.MustCompile(`(?i)-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----`),
	regexp.MustCompile(`(?i)https?://[^\s/@:]+:[^\s/@]+@`),
	regexp.MustCompile(`(?i)"(?:api[_-]?key|access[_-]?token|password|passwd|secret|authorization)"\s*:\s*"[^"\s]{4,}"`),
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
	for _, pattern := range secretPatterns {
		if pattern.Match(body) {
			return ErrUnsafeContent
		}
	}
	return nil
}
