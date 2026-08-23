package vulnerabilities

import (
	"encoding/json"
	"errors"
	"net/url"

	"hunter.local/assistant/mcp/internal/actionreceipt"
	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
)

type vulnerabilityInput struct {
	Name        *string  `json:"name,omitempty"`
	Severity    *string  `json:"severity,omitempty"`
	Type        *string  `json:"type,omitempty"`
	CWE         *string  `json:"cwe,omitempty"`
	Status      *string  `json:"status,omitempty"`
	Program     *string  `json:"program,omitempty"`
	Tool        *string  `json:"tool,omitempty"`
	Asset       *string  `json:"asset,omitempty"`
	Description *string  `json:"description,omitempty"`
	Impact      *string  `json:"impact,omitempty"`
	Host        *string  `json:"host,omitempty"`
	URL         *string  `json:"url,omitempty"`
	IP          *string  `json:"ip,omitempty"`
	Method      *string  `json:"method,omitempty"`
	Request     *string  `json:"request,omitempty"`
	Response    *string  `json:"response,omitempty"`
	Curl        *string  `json:"curl,omitempty"`
	Extracted   *string  `json:"extracted,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	Port        *int     `json:"port,omitempty"`
	Submitted   *bool    `json:"submitted,omitempty"`
	Confidence  *float64 `json:"confidence,omitempty"`
}

type createInput struct {
	Vulnerability vulnerabilityInput `json:"vulnerability"`
}

type updateInput struct {
	ID              string             `json:"id"`
	ExpectedVersion string             `json:"expected_version"`
	Vulnerability   vulnerabilityInput `json:"vulnerability"`
}

func vulnerabilityWriteTools() []tool.Tool {
	return []tool.Tool{
		{
			Name: "create_vulnerability", Scope: "vulnerabilities_create", WriteScope: true,
			Description: "Create one nonsecret vulnerability using the reviewed field set.",
			InputSchema: vulnerabilitySchema(false), OutputSchema: actionreceipt.Schema(),
			Decode: decodeCreate, BuildRequest: buildCreate,
			Validate: actionreceipt.Validate("create_vulnerability"),
		},
		{
			Name: "update_vulnerability", Scope: "vulnerabilities_update", WriteScope: true,
			Description: "Update one vulnerability through its safe version precondition.",
			InputSchema: vulnerabilitySchema(true), OutputSchema: actionreceipt.Schema(),
			Decode: decodeUpdate, BuildRequest: buildUpdate,
			Validate: actionreceipt.Validate("update_vulnerability"),
		},
	}
}

func vulnerabilitySchema(update bool) json.RawMessage {
	properties := map[string]any{
		"name":        map[string]any{"type": "string", "maxLength": 500},
		"severity":    map[string]any{"type": "string", "maxLength": 32},
		"type":        map[string]any{"type": "string", "maxLength": 200},
		"cwe":         map[string]any{"type": "string", "maxLength": 64},
		"status":      map[string]any{"type": "string", "maxLength": 64},
		"program":     map[string]any{"type": "string", "maxLength": 255},
		"tool":        map[string]any{"type": "string", "maxLength": 255},
		"asset":       map[string]any{"type": "string", "maxLength": 2048},
		"description": map[string]any{"type": "string", "maxLength": 16384},
		"impact":      map[string]any{"type": "string", "maxLength": 16384},
		"host":        map[string]any{"type": "string", "maxLength": 2048},
		"url":         map[string]any{"type": "string", "maxLength": 8192},
		"ip":          map[string]any{"type": "string", "maxLength": 128},
		"method":      map[string]any{"type": "string", "maxLength": 32},
		"request":     map[string]any{"type": "string", "maxLength": 16384},
		"response":    map[string]any{"type": "string", "maxLength": 16384},
		"curl":        map[string]any{"type": "string", "maxLength": 16384},
		"extracted":   map[string]any{"type": "string", "maxLength": 16384},
		"tags":        map[string]any{"type": "array", "maxItems": 100, "items": map[string]any{"type": "string", "maxLength": 200}},
		"port":        map[string]any{"type": "integer", "minimum": 1, "maximum": 65535},
		"submitted":   map[string]any{"type": "boolean"},
		"confidence":  map[string]any{"type": "number", "minimum": 0, "maximum": 1},
	}
	vulnerability := map[string]any{"type": "object", "additionalProperties": false, "properties": properties}
	rootProperties := map[string]any{"vulnerability": vulnerability}
	required := []string{"vulnerability"}
	if !update {
		vulnerability["required"] = []string{"name"}
	} else {
		rootProperties["id"] = map[string]any{"type": "string", "pattern": "^[0-9a-fA-F]{24}$"}
		rootProperties["expected_version"] = map[string]any{"type": "string", "minLength": 1, "maxLength": 255}
		required = append(required, "id", "expected_version")
	}
	encoded, _ := json.Marshal(map[string]any{
		"type": "object", "additionalProperties": false, "required": required, "properties": rootProperties,
	})
	return encoded
}

func decodeCreate(args []byte) (tool.Request, error) {
	var input createInput
	if codec.DecodeClosed(args, &input) != nil || input.Vulnerability.Name == nil ||
		!validVulnerability(input.Vulnerability) || redact.NewChecker(1<<20).Check(args) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: input}, nil
}

func decodeUpdate(args []byte) (tool.Request, error) {
	var input updateInput
	if codec.DecodeClosed(args, &input) != nil || len(input.ID) != 24 || input.ExpectedVersion == "" ||
		len(input.ExpectedVersion) > 255 || !validVulnerability(input.Vulnerability) ||
		redact.NewChecker(1<<20).Check(args) != nil {
		return tool.Request{}, codec.ErrInvalid
	}
	return tool.Request{Payload: input}, nil
}

func validVulnerability(input vulnerabilityInput) bool {
	limits := map[*string]int{
		input.Name: 500, input.Severity: 32, input.Type: 200, input.CWE: 64, input.Status: 64,
		input.Program: 255, input.Tool: 255, input.Asset: 2048, input.Description: 16384,
		input.Impact: 16384, input.Host: 2048, input.URL: 8192, input.IP: 128,
		input.Method: 32, input.Request: 16384, input.Response: 16384, input.Curl: 16384,
		input.Extracted: 16384,
	}
	for value, limit := range limits {
		if value != nil && len(*value) > limit {
			return false
		}
	}
	if len(input.Tags) > 100 {
		return false
	}
	for _, tag := range input.Tags {
		if len(tag) > 200 {
			return false
		}
	}
	return (input.Port == nil || (*input.Port >= 1 && *input.Port <= 65535)) &&
		(input.Confidence == nil || (*input.Confidence >= 0 && *input.Confidence <= 1))
}

func buildCreate(request tool.Request) (tool.Call, error) {
	input := request.Payload.(createInput)
	body, err := json.Marshal(input)
	if err != nil {
		return tool.Call{}, errors.New("invalid vulnerability input")
	}
	return tool.Call{Method: "POST", Path: "/api/v1/assistant/machine/vulnerabilities", Body: body}, nil
}

func buildUpdate(request tool.Request) (tool.Call, error) {
	input := request.Payload.(updateInput)
	body, err := json.Marshal(map[string]any{
		"expected_version": input.ExpectedVersion, "vulnerability": input.Vulnerability,
	})
	if err != nil {
		return tool.Call{}, errors.New("invalid vulnerability input")
	}
	return tool.Call{
		Method: "PATCH", Path: "/api/v1/assistant/machine/vulnerabilities/" + url.PathEscape(input.ID), Body: body,
	}, nil
}
