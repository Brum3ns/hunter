package config

import (
	"errors"
	"os"
	"strings"
)

// Load is the production entry point: the validator's one machine
// credential — the HTTP ingress token Rails presents on every
// POST /validations — comes from the process environment. It fails only
// when that token is missing or malformed.
func Load() (Config, error) {
	ingressToken := os.Getenv("ASSISTANT_VALIDATOR_INGRESS_TOKEN")
	if !validCredential(ingressToken) {
		return Config{}, errors.New("assistant validator machine credential rejected")
	}
	return Config{IngressToken: ingressToken}, nil
}

type Config struct {
	IngressToken string
}

// validCredential rejects NUL, CR, LF, tab and space. Duplicated from the
// gateway's helper of the same name rather than shared: the two services are
// independent Go modules with narrow Docker build contexts, so importing
// across them would need a raised context plus a replace directive.
func validCredential(value string) bool {
	return value != "" && len(value) <= 1024 && !strings.ContainsAny(value, "\x00\r\n\t ")
}
