// Package codec holds the closed-JSON decode helpers shared by every module.
package codec

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"regexp"
	"unicode/utf8"
)

const MaxInputBytes = 64 << 10

// SafeID bounds every resource/id string a tool accepts or a grant authorizes.
var SafeID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,254}$`)

var ErrInvalid = errors.New("invalid closed input")

// DecodeClosed strictly decodes a single JSON object with no unknown or trailing data.
func DecodeClosed(input []byte, destination any) error {
	if len(input) == 0 || len(input) > MaxInputBytes || !utf8.Valid(input) {
		return ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return ErrInvalid
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalid
	}
	return nil
}

// DecodeRawClosed is DecodeClosed for an already-extracted json.RawMessage.
func DecodeRawClosed(input json.RawMessage, destination any) error {
	if !utf8.Valid(input) {
		return ErrInvalid
	}
	decoder := json.NewDecoder(bytes.NewReader(input))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); err != io.EOF {
		return ErrInvalid
	}
	return nil
}

// ExactKeys reports whether fields has exactly the required keys, no more, no fewer.
func ExactKeys(fields map[string]json.RawMessage, required []string) bool {
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
