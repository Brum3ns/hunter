package mcp_test

import (
	"testing"

	"hunter.local/assistant/mcp/internal/tools"
)

func FuzzToolInput(f *testing.F) {
	f.Add([]byte(`{"type":"target","id":"abc"}`))
	f.Add([]byte(`{"url":"http://127.0.0.1"}`))
	f.Fuzz(func(t *testing.T, input []byte) {
		if len(input) > 1<<20 {
			t.Skip()
		}
		_, _ = tools.DecodeExactResource(input)
	})
}
