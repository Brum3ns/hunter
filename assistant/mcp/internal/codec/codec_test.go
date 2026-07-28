package codec

import (
	"encoding/json"
	"strings"
	"testing"
)

type sample struct {
	A string `json:"a"`
}

func TestDecodeClosedRejects(t *testing.T) {
	cases := map[string]string{
		"empty":        ``,
		"unknownField": `{"a":"x","b":1}`,
		"trailing":     `{"a":"x"}{}`,
		"notObject":    `[]`,
		"tooLarge":     `{"a":"` + strings.Repeat("x", MaxInputBytes) + `"}`,
	}
	for name, in := range cases {
		var dst sample
		if err := DecodeClosed([]byte(in), &dst); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
	var dst sample
	if err := DecodeClosed([]byte(`{"a":"x"}`), &dst); err != nil || dst.A != "x" {
		t.Fatalf("valid input rejected: %v", err)
	}
}

func TestDecodeClosedRejectsBadUTF8(t *testing.T) {
	in := append([]byte(`{"a":"`), 0xff)
	in = append(in, []byte(`"}`)...)
	var dst sample
	if err := DecodeClosed(in, &dst); err == nil {
		t.Fatal("expected bad-utf8 rejection")
	}
}

func TestExactKeys(t *testing.T) {
	f := map[string]json.RawMessage{"a": json.RawMessage(`1`), "b": json.RawMessage(`2`)}
	if !ExactKeys(f, []string{"a", "b"}) {
		t.Fatal("exact match should pass")
	}
	if ExactKeys(f, []string{"a"}) {
		t.Fatal("extra key should fail")
	}
	if ExactKeys(f, []string{"a", "b", "c"}) {
		t.Fatal("missing key should fail")
	}
}
