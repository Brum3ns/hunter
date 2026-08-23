package operational

import (
	"encoding/json"
	"fmt"
	"net/url"
	"slices"
	"strings"

	"hunter.local/assistant/mcp/internal/actionreceipt"
	"hunter.local/assistant/mcp/internal/codec"
	"hunter.local/assistant/mcp/internal/redact"
	"hunter.local/assistant/mcp/internal/tool"
)

type rawInput map[string]json.RawMessage
type inputValidator func(rawInput) bool

type customSpec struct {
	name, description, method string
	schema                    json.RawMessage
	validate                  inputValidator
	path                      func(rawInput) string
	bodyKeys                  []string
	validateOutput            func([]byte) error
}

func customTools() []tool.Tool {
	empty := schema(nil, nil)
	id := schema(map[string]any{"id": intProperty(1, 9_999_999_999_999_999)}, []string{"id"})
	return []tool.Tool{
		makeCustom(customSpec{
			name: "validate_whiterabbit_template", description: "Validate a complete Whiterabbit template without saving it.", method: "POST",
			schema: templateValidationSchema(), validate: validateTemplate,
			path: fixed("/api/v1/assistant/machine/control_center/templates/validate"), bodyKeys: []string{"template"},
			validateOutput: validateValidation,
		}),
		makeCustom(customSpec{
			name: "validate_whiterabbit_yaml", description: "Parse and validate Whiterabbit template YAML without saving it.", method: "POST",
			schema: schema(map[string]any{"yaml": stringProperty(65_536)}, []string{"yaml"}), validate: validateString("yaml", 65_536),
			path: fixed("/api/v1/assistant/machine/control_center/templates/validate_yaml"), bodyKeys: []string{"yaml"},
			validateOutput: validateValidation,
		}),
		makeCustom(customSpec{
			name: "resolve_job_targets", description: "Resolve and sample a bounded Whiterabbit target selection without submitting a job.", method: "POST",
			schema: jobSchema(false), validate: validateJob(false),
			path: fixed("/api/v1/assistant/machine/control_center/jobs/resolve_targets"), bodyKeys: jobKeys,
			validateOutput: validateTargetResolution,
		}),
		makeCustom(customSpec{
			name: "submit_whiterabbit_job", description: "Submit one validated Whiterabbit job using exact target selections or manual targets.", method: "POST",
			schema: jobSchema(true), validate: validateJob(true),
			path: fixed("/api/v1/assistant/machine/control_center/jobs"), bodyKeys: jobKeys,
			validateOutput: actionreceipt.Validate("submit_whiterabbit_job"),
		}),
		makeCustom(customSpec{
			name: "get_control_center_health", description: "Read safe RabbitMQ and Mongo Control Center availability flags.", method: "GET",
			schema: empty, validate: validateEmpty, path: fixed("/api/v1/assistant/machine/control_center/health"),
			validateOutput: validateControlCenterHealth,
		}),
		makeCustom(customSpec{
			name: "get_control_center_stats", description: "Read bounded Control Center job statistics and trends.", method: "GET",
			schema: empty, validate: validateEmpty, path: fixed("/api/v1/assistant/machine/control_center/stats"),
			validateOutput: validateControlCenterStats,
		}),
		makeCustom(customSpec{
			name: "validate_ansible_playbook", description: "Run Hunter's fail-closed Assistant Ansible validator without saving.", method: "POST",
			schema: schema(map[string]any{"yaml_content": stringProperty(65_536)}, []string{"yaml_content"}), validate: validateString("yaml_content", 65_536),
			path: fixed("/api/v1/assistant/machine/control_center/ansible/playbooks/validate"), bodyKeys: []string{"yaml_content"},
			validateOutput: validateValidation,
		}),
		makeCustom(customSpec{
			name: "export_ansible_playbooks", description: "Create a short-lived human-owned browser download for selected playbooks; archive bytes never enter the model.", method: "POST",
			schema: schema(map[string]any{"ids": idArrayProperty(1, 100)}, []string{"ids"}), validate: validateIDArray("ids", 1, 100),
			path: fixed("/api/v1/assistant/machine/control_center/ansible/playbooks/export"), bodyKeys: []string{"ids"},
			validateOutput: validateExportReceipt,
		}),
		makeCustom(customSpec{
			name: "validate_ansible_inventory", description: "Validate Ansible inventory YAML without saving it.", method: "POST",
			schema: schema(map[string]any{"yaml_content": stringProperty(262_144)}, []string{"yaml_content"}), validate: validateString("yaml_content", 262_144),
			path: fixed("/api/v1/assistant/machine/control_center/ansible/inventories/validate"), bodyKeys: []string{"yaml_content"},
			validateOutput: validateValidation,
		}),
		makeCustom(customSpec{
			name: "create_ansible_inventory", description: "Create a validated nonsecret Ansible inventory.", method: "POST",
			schema: inventoryCreateSchema(), validate: validateInventoryCreate,
			path: fixed("/api/v1/assistant/machine/control_center/ansible/inventories"), bodyKeys: []string{"inventory"},
			validateOutput: actionreceipt.Validate("create_ansible_inventory"),
		}),
		makeCustom(customSpec{
			name: "edit_ansible_inventory", description: "Version-edit one validated nonsecret Ansible inventory.", method: "PATCH",
			schema: inventoryEditSchema(), validate: validateInventoryEdit,
			path: pathID("/api/v1/assistant/machine/control_center/ansible/inventories/%s", "id"), bodyKeys: []string{"expected_lock_version", "changes"},
			validateOutput: actionreceipt.Validate("edit_ansible_inventory"),
		}),
		makeCustom(customSpec{
			name: "queue_inventory_syntax_check", description: "Queue an inventory/playbook syntax check.", method: "POST",
			schema:   schema(map[string]any{"id": intProperty(1, maxID), "playbook_id": intProperty(1, maxID)}, []string{"id", "playbook_id"}),
			validate: validatePositiveIDs("id", "playbook_id"), path: pathID("/api/v1/assistant/machine/control_center/ansible/inventories/%s/syntax_check", "id"), bodyKeys: []string{"playbook_id"},
			validateOutput: actionreceipt.Validate("queue_inventory_syntax_check"),
		}),
		makeCustom(customSpec{
			name: "queue_host_key_scan", description: "Queue host-key discovery for one inventory.", method: "POST",
			schema: id, validate: validatePositiveIDs("id"), path: pathID("/api/v1/assistant/machine/control_center/ansible/inventories/%s/host_key_scan", "id"), bodyKeys: []string{},
			validateOutput: actionreceipt.Validate("queue_host_key_scan"),
		}),
		makeCustom(customSpec{
			name: "confirm_inventory_host_keys", description: "Confirm an exact scanned host-key candidate set with an inventory lock precondition.", method: "POST",
			schema: hostKeySchema(), validate: validateHostKeys,
			path: pathID("/api/v1/assistant/machine/control_center/ansible/inventories/%s/confirm_host_keys", "id"), bodyKeys: []string{"expected_lock_version", "candidates"},
			validateOutput: actionreceipt.Validate("confirm_inventory_host_keys"),
		}),
		makeCustom(customSpec{
			name: "queue_inventory_connectivity_test", description: "Queue a bounded connectivity test using an opaque existing credential ID.", method: "POST",
			schema:   schema(map[string]any{"id": intProperty(1, maxID), "credential_id": intProperty(1, maxID)}, []string{"id"}),
			validate: validateOptionalPositiveID("id", "credential_id"), path: pathID("/api/v1/assistant/machine/control_center/ansible/inventories/%s/connectivity_test", "id"), bodyKeys: []string{"credential_id"},
			validateOutput: actionreceipt.Validate("queue_inventory_connectivity_test"),
		}),
		makeCustom(customSpec{
			name: "get_inventory_utility_task", description: "Read a redacted inventory utility-task result.", method: "GET",
			schema:   schema(map[string]any{"id": intProperty(1, maxID), "task_id": intProperty(1, maxID)}, []string{"id", "task_id"}),
			validate: validatePositiveIDs("id", "task_id"), path: pathTwoIDs("/api/v1/assistant/machine/control_center/ansible/inventories/%s/utility_tasks/%s", "id", "task_id"),
			validateOutput: validateUtilityTask,
		}),
		makeCustom(customSpec{
			name: "create_ansible_variable_set", description: "Create an Ansible variable set without secret values.", method: "POST",
			schema: variableSetCreateSchema(), validate: validateVariableSetCreate,
			path: fixed("/api/v1/assistant/machine/control_center/ansible/variable_sets"), bodyKeys: []string{"variable_set"},
			validateOutput: actionreceipt.Validate("create_ansible_variable_set"),
		}),
		makeCustom(customSpec{
			name: "edit_ansible_variable_set", description: "Version-edit an Ansible variable set without secret values.", method: "PATCH",
			schema: variableSetEditSchema(), validate: validateVariableSetEdit,
			path: pathID("/api/v1/assistant/machine/control_center/ansible/variable_sets/%s", "id"), bodyKeys: []string{"expected_lock_version", "changes"},
			validateOutput: actionreceipt.Validate("edit_ansible_variable_set"),
		}),
		makeCustom(customSpec{
			name: "create_nonsecret_ansible_variable", description: "Create one explicitly nonsecret typed Ansible variable.", method: "POST",
			schema: variableCreateSchema(), validate: validateVariableCreate,
			path: pathID("/api/v1/assistant/machine/control_center/ansible/variable_sets/%s/variables", "variable_set_id"), bodyKeys: []string{"variable"},
			validateOutput: actionreceipt.Validate("create_nonsecret_ansible_variable"),
		}),
		makeCustom(customSpec{
			name: "edit_nonsecret_ansible_variable", description: "Version-edit one existing nonsecret typed Ansible variable.", method: "PATCH",
			schema: variableEditSchema(), validate: validateVariableEdit,
			path: pathTwoIDs("/api/v1/assistant/machine/control_center/ansible/variable_sets/%s/variables/%s", "variable_set_id", "id"), bodyKeys: []string{"expected_lock_version", "changes"},
			validateOutput: actionreceipt.Validate("edit_nonsecret_ansible_variable"),
		}),
		makeCustom(customSpec{
			name: "launch_ansible_run_group", description: "Launch one validated Ansible run using existing reviewed artifacts and opaque credential metadata.", method: "POST",
			schema: launchSchema(), validate: validateLaunch,
			path: fixed("/api/v1/assistant/machine/control_center/ansible/run_groups"), bodyKeys: launchKeys,
			validateOutput: actionreceipt.Validate("launch_ansible_run_group"),
		}),
		makeCustom(customSpec{
			name: "cancel_ansible_run_group", description: "Request cancellation of one nonterminal Ansible run group without deleting it.", method: "POST",
			schema: id, validate: validatePositiveIDs("id"), path: pathID("/api/v1/assistant/machine/control_center/ansible/run_groups/%s/cancel", "id"), bodyKeys: []string{},
			validateOutput: actionreceipt.Validate("cancel_ansible_run_group"),
		}),
		makeCustom(customSpec{
			name: "cancel_ansible_run", description: "Request cancellation of one nonterminal Ansible run without deleting it.", method: "POST",
			schema: id, validate: validatePositiveIDs("id"), path: pathID("/api/v1/assistant/machine/control_center/ansible/runs/%s/cancel", "id"), bodyKeys: []string{},
			validateOutput: actionreceipt.Validate("cancel_ansible_run"),
		}),
		makeCustom(customSpec{
			name: "get_ansible_executor_health", description: "Read bounded Ansible executor capacity and queue age metadata.", method: "GET",
			schema: empty, validate: validateEmpty, path: fixed("/api/v1/assistant/machine/control_center/ansible/executor_health"),
			validateOutput: validateExecutorHealth,
		}),
	}
}

func makeCustom(spec customSpec) tool.Tool {
	outputSchema := tool.ResultSchema
	if strings.Contains(spec.name, "create_") || strings.Contains(spec.name, "edit_") ||
		strings.HasPrefix(spec.name, "queue_") || strings.HasPrefix(spec.name, "submit_") ||
		strings.HasPrefix(spec.name, "launch_") || strings.HasPrefix(spec.name, "cancel_") ||
		spec.name == "confirm_inventory_host_keys" {
		outputSchema = actionreceipt.Schema()
	}
	return tool.Tool{
		Name: spec.name, Description: spec.description, InputSchema: spec.schema, OutputSchema: outputSchema,
		Decode: func(args []byte) (tool.Request, error) {
			var raw rawInput
			if codec.DecodeClosed(args, &raw) != nil || !spec.validate(raw) || redact.NewChecker(codec.MaxInputBytes).Check(args) != nil {
				return tool.Request{}, codec.ErrInvalid
			}
			return tool.Request{Payload: raw}, nil
		},
		BuildRequest: func(request tool.Request) (tool.Call, error) {
			raw, ok := request.Payload.(rawInput)
			if !ok {
				return tool.Call{}, codec.ErrInvalid
			}
			var body []byte
			if spec.method != "GET" {
				selected := rawInput{}
				for _, key := range spec.bodyKeys {
					if value, present := raw[key]; present {
						selected[key] = value
					}
				}
				var err error
				body, err = json.Marshal(selected)
				if err != nil || len(body) > codec.MaxInputBytes {
					return tool.Call{}, codec.ErrInvalid
				}
			}
			return tool.Call{Method: spec.method, Path: spec.path(raw), Body: body}, nil
		},
		Validate: spec.validateOutput,
	}
}

func fixed(path string) func(rawInput) string { return func(rawInput) string { return path } }

func pathID(format, key string) func(rawInput) string {
	return func(raw rawInput) string { return fmt.Sprintf(format, url.PathEscape(integerText(raw[key]))) }
}

func pathTwoIDs(format, first, second string) func(rawInput) string {
	return func(raw rawInput) string {
		return fmt.Sprintf(format, url.PathEscape(integerText(raw[first])), url.PathEscape(integerText(raw[second])))
	}
}

func integerText(raw json.RawMessage) string { return strings.TrimSpace(string(raw)) }

func validateEmpty(raw rawInput) bool { return len(raw) == 0 }

func exact(raw rawInput, allowed, required []string) bool {
	if len(raw) > len(allowed) {
		return false
	}
	for key := range raw {
		if !slices.Contains(allowed, key) {
			return false
		}
	}
	for _, key := range required {
		if _, present := raw[key]; !present {
			return false
		}
	}
	return true
}
