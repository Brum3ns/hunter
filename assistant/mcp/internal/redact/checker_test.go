package redact

import "testing"

func TestCheckerRejectsSecretsAndOversizedBodies(t *testing.T) {
	checker := NewChecker(64)
	for _, body := range [][]byte{
		[]byte(`{"authorization":"Bearer secret"}`),
		[]byte(`{"key":"-----BEGIN PRIVATE KEY-----"}`),
		[]byte(`{"url":"https://user:pass@example.test"}`),
		[]byte(`{"command":"curl -H 'Cookie: session=do-not-return' https://example.test"}`),
		[]byte(`{"value":"client_secret=do-not-return"}`),
		[]byte(`{"value":"refresh_token: do-not-return"}`),
		[]byte(`{"client_secret":"do-not-return"}`),
		make([]byte, 65),
	} {
		if err := checker.Check(body); err == nil {
			t.Fatalf("accepted %q", body)
		}
	}
}

func TestCheckerAcceptsBoundedSanitizedJSON(t *testing.T) {
	for _, body := range [][]byte{
		[]byte(`{"host":"example.test"}`),
		[]byte(`{"client_secret":"[REDACTED]"}`),
	} {
		if err := NewChecker(1024).Check(body); err != nil {
			t.Fatal(err)
		}
	}
}
