package resource

import "testing"

func TestDecodeAcceptsGrantedTypes(t *testing.T) {
	in, err := Decode([]byte(`{"type":"target","id":"host-1"}`))
	if err != nil || in.Type != "target" || in.ID != "host-1" {
		t.Fatalf("valid resource rejected: %v", err)
	}
}

func TestDecodeRejects(t *testing.T) {
	for _, in := range []string{
		`{"type":"bogus","id":"x"}`,
		`{"type":"target","id":"bad id"}`,
		`{"type":"target","id":"../../all"}`,
		`{"type":"target"}`,
		`{"type":"target","id":"x","extra":1}`,
	} {
		if _, err := Decode([]byte(in)); err == nil {
			t.Errorf("expected rejection for %s", in)
		}
	}
}
