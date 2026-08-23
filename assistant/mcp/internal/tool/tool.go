// Package tool holds the dependency-free contracts every MCP module and the
// runner share. It imports nothing from the rest of the service.
package tool

import "encoding/json"

// Resource is an explicit {type,id} pair a turn grant may authorize.
type Resource struct {
	Type string `json:"type"`
	ID   string `json:"id"`
}

// Call is a machine-namespace request a module produces; the transport runs it.
type Call struct {
	Method string
	Path   string
	Body   []byte // nil for GET
}

// Request is a decoded, validated tool input plus the optional resource it targets.
type Request struct {
	Payload  any
	Resource *Resource
}

// Tool is a fully self-describing MCP tool the runner drives generically.
type Tool struct {
	Name                string
	Description         string
	InputSchema         json.RawMessage
	OutputSchema        json.RawMessage
	Module              string
	Effect              string
	Scope               string // dedicated scope required; "" = no scope gate
	WriteScope          bool   // true selects the grant's write scopes, never its read scopes
	RequiresResource    bool   // true iff an explicit resource grant is required
	Gate                string
	RateProfile         string
	ByteProfile         string
	Idempotency         string
	MachineMethod       string
	MachinePath         string
	InputSchemaVersion  int
	OutputSchemaVersion int

	Decode       func(args []byte) (Request, error)
	BuildRequest func(req Request) (Call, error)
	Validate     func(payload []byte) error
}

// Module contributes a set of tools to the registry.
type Module interface {
	Tools() []Tool
}

// ResultSchema is the shared output envelope every tool advertises: {result:object}.
var ResultSchema = json.RawMessage(`{
    "type":"object","additionalProperties":false,"required":["result"],
    "properties":{"result":{"type":"object"}}
  }`)
