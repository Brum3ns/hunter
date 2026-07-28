package policies

import (
	"encoding/json"

	"hunter.local/assistant/mcp/internal/codec"
)

func validArtifactType(value string) bool {
	return value == "whiterabbit_template" || value == "ansible_playbook"
}

// validateKeys enforces that payload is a closed object with exactly required keys.
func validateKeys(payload []byte, required []string) error {
	var root map[string]json.RawMessage
	if err := codec.DecodeRawClosed(payload, &root); err != nil {
		return err
	}
	if !codec.ExactKeys(root, required) {
		return codec.ErrInvalid
	}
	return nil
}
