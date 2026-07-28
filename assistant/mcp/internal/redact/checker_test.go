package redact

import "testing"

func TestCheckerRejectsSecretsAndOversizedBodies(t *testing.T) {
	checker := NewChecker(64)
	for _, body := range [][]byte{
		[]byte(`{"authorization":"Bearer secret"}`),
		[]byte(`{"key":"-----BEGIN PRIVATE KEY-----"}`),
		[]byte(`{"url":"https://user:pass@example.test"}`),
		make([]byte, 65),
	} {
		if err := checker.Check(body); err == nil {
			t.Fatalf("accepted %q", body)
		}
	}
}

func TestCheckerAcceptsBoundedSanitizedJSON(t *testing.T) {
	if err := NewChecker(1024).Check([]byte(`{"host":"example.test"}`)); err != nil {
		t.Fatal(err)
	}
}
