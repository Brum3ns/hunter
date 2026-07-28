// Package resource decodes the {type,id} reference shared by resource-bound tools.
package resource

import (
	"encoding/json"
	"slices"

	"hunter.local/assistant/mcp/internal/codec"
)

// Types is the closed set of resource kinds a grant may reference.
var Types = []string{
	"program", "target", "cve", "vulnerability", "whiterabbit_template", "ansible_playbook",
}

// Schema is the advertised input schema for resource-bound tools.
var Schema = json.RawMessage(`{
    "type":"object",
    "additionalProperties":false,
    "required":["type","id"],
    "properties":{
      "type":{"type":"string","enum":["program","target","cve","vulnerability","whiterabbit_template","ansible_playbook"]},
      "id":{"type":"string","minLength":1,"maxLength":255,"pattern":"^[A-Za-z0-9][A-Za-z0-9._:-]*$"}
    }
  }`)

type Input struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

// Decode strictly parses a resource reference, enforcing the type enum and id shape.
func Decode(args []byte) (Input, error) {
	var in Input
	if err := codec.DecodeClosed(args, &in); err != nil || !slices.Contains(Types, in.Type) || !codec.SafeID.MatchString(in.ID) {
		return Input{}, codec.ErrInvalid
	}
	return in, nil
}
