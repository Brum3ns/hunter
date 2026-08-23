// Package catalog contains the checked, generated metadata for Hunter's
// reviewed Assistant capabilities. It describes authority; individual modules
// still own closed input decoding, request construction, and output validation.
package catalog

import (
	"errors"
	"regexp"
	"slices"
	"strings"
)

type Definition struct {
	Name                string
	Module              string
	Effect              string
	Scope               string
	Method              string
	Path                string
	Gate                string
	RateProfile         string
	ByteProfile         string
	Idempotency         string
	InputSchemaVersion  int
	OutputSchemaVersion int
	Rollout             string
}

var definitions = []Definition{
	{Name: "list_hunter_capabilities", Module: "catalog", Effect: "read", Scope: "hunter_capabilities_read", Method: "GET", Path: "/api/v1/assistant/machine/capabilities", Gate: "catalog", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_targets", Module: "targets", Effect: "read", Scope: "targets_read", Method: "GET", Path: "/api/v1/assistant/machine/targets", Gate: "targets", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_target", Module: "targets", Effect: "read", Scope: "targets_read", Method: "GET", Path: "/api/v1/assistant/machine/targets/{id}", Gate: "targets", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_targets", Module: "targets", Effect: "analyze", Scope: "targets_read", Method: "POST", Path: "/api/v1/assistant/machine/targets/analyze", Gate: "targets", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_endpoints", Module: "sitemap", Effect: "read", Scope: "sitemap_read", Method: "GET", Path: "/api/v1/assistant/machine/sitemap/endpoints", Gate: "sitemap", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_endpoint", Module: "sitemap", Effect: "read", Scope: "sitemap_read", Method: "GET", Path: "/api/v1/assistant/machine/sitemap/endpoints/{id}", Gate: "sitemap", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_endpoints", Module: "sitemap", Effect: "analyze", Scope: "sitemap_read", Method: "POST", Path: "/api/v1/assistant/machine/sitemap/endpoints/analyze", Gate: "sitemap", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_programs", Module: "programs", Effect: "read", Scope: "programs_read", Method: "GET", Path: "/api/v1/assistant/machine/programs", Gate: "programs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_program", Module: "programs", Effect: "read", Scope: "programs_read", Method: "GET", Path: "/api/v1/assistant/machine/programs/{id}", Gate: "programs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_programs", Module: "programs", Effect: "analyze", Scope: "programs_read", Method: "POST", Path: "/api/v1/assistant/machine/programs/analyze", Gate: "programs", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_program_changes", Module: "programs", Effect: "read", Scope: "programs_read", Method: "GET", Path: "/api/v1/assistant/machine/programs/changes", Gate: "programs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_scope_runs", Module: "programs", Effect: "read", Scope: "programs_read", Method: "GET", Path: "/api/v1/assistant/machine/programs/scope_runs", Gate: "programs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_scope_run", Module: "programs", Effect: "read", Scope: "programs_read", Method: "GET", Path: "/api/v1/assistant/machine/programs/scope_runs/{id}", Gate: "programs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_cves", Module: "cves", Effect: "read", Scope: "cves_read", Method: "GET", Path: "/api/v1/assistant/machine/cves", Gate: "cves", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_cve", Module: "cves", Effect: "read", Scope: "cves_read", Method: "GET", Path: "/api/v1/assistant/machine/cves/{id}", Gate: "cves", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_new_cves", Module: "cves", Effect: "read", Scope: "cves_read", Method: "GET", Path: "/api/v1/assistant/machine/cves/new", Gate: "cves", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_cves", Module: "cves", Effect: "analyze", Scope: "cves_read", Method: "POST", Path: "/api/v1/assistant/machine/cves/analyze", Gate: "cves", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_vulnerabilities", Module: "vulnerabilities", Effect: "read", Scope: "vulnerabilities_read", Method: "GET", Path: "/api/v1/assistant/machine/vulnerabilities", Gate: "vulnerabilities", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_vulnerability", Module: "vulnerabilities", Effect: "read", Scope: "vulnerabilities_read", Method: "GET", Path: "/api/v1/assistant/machine/vulnerabilities/{id}", Gate: "vulnerabilities", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_vulnerabilities", Module: "vulnerabilities", Effect: "analyze", Scope: "vulnerabilities_read", Method: "POST", Path: "/api/v1/assistant/machine/vulnerabilities/analyze", Gate: "vulnerabilities", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_vulnerability", Module: "vulnerabilities", Effect: "create", Scope: "vulnerabilities_create", Method: "POST", Path: "/api/v1/assistant/machine/vulnerabilities", Gate: "vulnerabilities", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "update_vulnerability", Module: "vulnerabilities", Effect: "update", Scope: "vulnerabilities_update", Method: "PATCH", Path: "/api/v1/assistant/machine/vulnerabilities/{id}", Gate: "vulnerabilities", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_templates", Module: "control_center_templates", Effect: "read", Scope: "control_center_templates_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/templates", Gate: "control_center_templates", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_template", Module: "control_center_templates", Effect: "read", Scope: "control_center_templates_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/templates/{id}", Gate: "control_center_templates", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_templates", Module: "control_center_templates", Effect: "analyze", Scope: "control_center_templates_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/templates/analyze", Gate: "control_center_templates", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "validate_whiterabbit_template", Module: "control_center_templates", Effect: "validate", Scope: "control_center_templates_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/templates/validate", Gate: "control_center_templates", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "validate_whiterabbit_yaml", Module: "control_center_templates", Effect: "validate", Scope: "control_center_templates_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/templates/validate_yaml", Gate: "control_center_templates", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_whiterabbit_template", Module: "control_center_templates", Effect: "create", Scope: "control_center_templates_write", Method: "POST", Path: "/api/v1/assistant/machine/control_center/templates", Gate: "control_center_templates", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "edit_whiterabbit_template", Module: "control_center_templates", Effect: "update", Scope: "control_center_templates_edit", Method: "PATCH", Path: "/api/v1/assistant/machine/control_center/templates/{id}", Gate: "control_center_templates", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_jobs", Module: "control_center_jobs", Effect: "read", Scope: "control_center_jobs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/jobs", Gate: "control_center_jobs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_job", Module: "control_center_jobs", Effect: "read", Scope: "control_center_jobs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/jobs/{id}", Gate: "control_center_jobs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_jobs", Module: "control_center_jobs", Effect: "analyze", Scope: "control_center_jobs_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/jobs/analyze", Gate: "control_center_jobs", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "resolve_job_targets", Module: "control_center_jobs", Effect: "analyze", Scope: "control_center_jobs_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/jobs/resolve_targets", Gate: "control_center_jobs", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "submit_whiterabbit_job", Module: "control_center_jobs", Effect: "execute", Scope: "control_center_jobs_submit", Method: "POST", Path: "/api/v1/assistant/machine/control_center/jobs", Gate: "control_center_jobs", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_control_center_health", Module: "control_center_jobs", Effect: "read", Scope: "control_center_jobs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/health", Gate: "control_center_jobs", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_control_center_stats", Module: "control_center_jobs", Effect: "analyze", Scope: "control_center_jobs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/stats", Gate: "control_center_jobs", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_ansible_credential_metadata", Module: "control_center_ansible_credentials", Effect: "read", Scope: "control_center_ansible_credentials_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/credentials", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_ansible_credential_metadata", Module: "control_center_ansible_credentials", Effect: "read", Scope: "control_center_ansible_credentials_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/credentials/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_playbooks", Module: "control_center_ansible_playbooks", Effect: "read", Scope: "control_center_ansible_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_playbook", Module: "control_center_ansible_playbooks", Effect: "read", Scope: "control_center_ansible_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_playbooks", Module: "control_center_ansible_playbooks", Effect: "analyze", Scope: "control_center_ansible_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks/analyze", Gate: "control_center_ansible_artifacts", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "validate_ansible_playbook", Module: "control_center_ansible_playbooks", Effect: "validate", Scope: "control_center_ansible_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks/validate", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "export_ansible_playbooks", Module: "control_center_ansible_playbooks", Effect: "export", Scope: "control_center_ansible_playbooks_export", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks/export", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_ansible_playbook", Module: "control_center_ansible_playbooks", Effect: "create", Scope: "control_center_ansible_write", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "edit_ansible_playbook", Module: "control_center_ansible_playbooks", Effect: "update", Scope: "control_center_ansible_edit", Method: "PATCH", Path: "/api/v1/assistant/machine/control_center/ansible/playbooks/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_ansible_inventories", Module: "control_center_ansible_inventories", Effect: "read", Scope: "control_center_ansible_inventories_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/inventories", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_ansible_inventory", Module: "control_center_ansible_inventories", Effect: "read", Scope: "control_center_ansible_inventories_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "validate_ansible_inventory", Module: "control_center_ansible_inventories", Effect: "validate", Scope: "control_center_ansible_inventories_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/validate", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_ansible_inventory", Module: "control_center_ansible_inventories", Effect: "create", Scope: "control_center_ansible_inventories_create", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "edit_ansible_inventory", Module: "control_center_ansible_inventories", Effect: "update", Scope: "control_center_ansible_inventories_edit", Method: "PATCH", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "queue_inventory_syntax_check", Module: "control_center_ansible_inventories", Effect: "execute", Scope: "control_center_ansible_inventory_syntax_check", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}/syntax_check", Gate: "control_center_ansible_artifacts", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "queue_host_key_scan", Module: "control_center_ansible_inventories", Effect: "execute", Scope: "control_center_ansible_inventory_host_key_scan", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}/host_key_scan", Gate: "control_center_ansible_artifacts", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "confirm_inventory_host_keys", Module: "control_center_ansible_inventories", Effect: "update", Scope: "control_center_ansible_inventory_host_keys_confirm", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}/confirm_host_keys", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "queue_inventory_connectivity_test", Module: "control_center_ansible_inventories", Effect: "execute", Scope: "control_center_ansible_inventory_connectivity_test", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}/connectivity_test", Gate: "control_center_ansible_artifacts", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_inventory_utility_task", Module: "control_center_ansible_inventories", Effect: "read", Scope: "control_center_ansible_inventories_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/inventories/{id}/utility_tasks/{task_id}", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_ansible_variable_sets", Module: "control_center_ansible_variables", Effect: "read", Scope: "control_center_ansible_variables_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_ansible_variable_set", Module: "control_center_ansible_variables", Effect: "read", Scope: "control_center_ansible_variables_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_ansible_variable_set", Module: "control_center_ansible_variables", Effect: "create", Scope: "control_center_ansible_variable_sets_create", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "edit_ansible_variable_set", Module: "control_center_ansible_variables", Effect: "update", Scope: "control_center_ansible_variable_sets_edit", Method: "PATCH", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "create_nonsecret_ansible_variable", Module: "control_center_ansible_variables", Effect: "create", Scope: "control_center_ansible_variables_create", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets/{variable_set_id}/variables", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "edit_nonsecret_ansible_variable", Module: "control_center_ansible_variables", Effect: "update", Scope: "control_center_ansible_variables_edit", Method: "PATCH", Path: "/api/v1/assistant/machine/control_center/ansible/variable_sets/{variable_set_id}/variables/{id}", Gate: "control_center_ansible_artifacts", RateProfile: "effect", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_run_groups", Module: "control_center_ansible_execution", Effect: "read", Scope: "control_center_ansible_runs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/run_groups", Gate: "control_center_ansible_execution", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_run_group", Module: "control_center_ansible_execution", Effect: "read", Scope: "control_center_ansible_runs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/run_groups/{id}", Gate: "control_center_ansible_execution", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "analyze_ansible_runs", Module: "control_center_ansible_execution", Effect: "analyze", Scope: "control_center_ansible_runs_read", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/run_groups/analyze", Gate: "control_center_ansible_execution", RateProfile: "analyze", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "launch_ansible_run_group", Module: "control_center_ansible_execution", Effect: "execute", Scope: "control_center_ansible_run_groups_launch", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/run_groups", Gate: "control_center_ansible_execution", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "cancel_ansible_run_group", Module: "control_center_ansible_execution", Effect: "cancel", Scope: "control_center_ansible_run_groups_cancel", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/run_groups/{id}/cancel", Gate: "control_center_ansible_execution", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_run", Module: "control_center_ansible_execution", Effect: "read", Scope: "control_center_ansible_runs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/runs/{id}", Gate: "control_center_ansible_execution", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "cancel_ansible_run", Module: "control_center_ansible_execution", Effect: "cancel", Scope: "control_center_ansible_runs_cancel", Method: "POST", Path: "/api/v1/assistant/machine/control_center/ansible/runs/{id}/cancel", Gate: "control_center_ansible_execution", RateProfile: "launch", ByteProfile: "standard", Idempotency: "required", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "list_run_events", Module: "control_center_ansible_execution", Effect: "read", Scope: "control_center_ansible_runs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/runs/{run_id}/events", Gate: "control_center_ansible_execution", RateProfile: "read", ByteProfile: "large", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
	{Name: "get_ansible_executor_health", Module: "control_center_ansible_execution", Effect: "read", Scope: "control_center_ansible_runs_read", Method: "GET", Path: "/api/v1/assistant/machine/control_center/ansible/executor_health", Gate: "control_center_ansible_execution", RateProfile: "read", ByteProfile: "standard", Idempotency: "none", InputSchemaVersion: 1, OutputSchemaVersion: 1, Rollout: "enabled"},
}

var safeIdentifier = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

func Definitions() []Definition {
	return slices.Clone(definitions)
}

func Names() []string {
	names := make([]string, 0, len(definitions))
	for _, definition := range definitions {
		names = append(names, definition.Name)
	}
	slices.Sort(names)
	return names
}

func Lookup(name string) (Definition, bool) {
	for _, definition := range definitions {
		if definition.Name == name {
			return definition, true
		}
	}
	return Definition{}, false
}

func Validate(candidates []Definition) error {
	names := make(map[string]struct{}, len(candidates))
	routes := make(map[string]struct{}, len(candidates))
	for _, definition := range candidates {
		if !safeIdentifier.MatchString(definition.Name) ||
			!safeIdentifier.MatchString(definition.Module) ||
			!safeIdentifier.MatchString(definition.Scope) ||
			strings.Contains(definition.Scope, "*") {
			return errors.New("invalid reviewed capability identifier")
		}
		for _, prohibited := range []string{"delete", "destroy", "purge", "request", "shell", "filesystem"} {
			if definition.Name == prohibited || strings.HasPrefix(definition.Name, prohibited+"_") {
				return errors.New("generic or destructive capability prohibited")
			}
		}
		if definition.Method != "GET" && definition.Method != "POST" &&
			definition.Method != "PATCH" && definition.Method != "PUT" {
			return errors.New("invalid reviewed capability method")
		}
		if !strings.HasPrefix(definition.Path, "/api/v1/assistant/machine/") {
			return errors.New("invalid reviewed capability route")
		}
		if definition.InputSchemaVersion <= 0 || definition.OutputSchemaVersion <= 0 ||
			definition.Rollout != "enabled" {
			return errors.New("invalid reviewed capability metadata")
		}
		if _, duplicate := names[definition.Name]; duplicate {
			return errors.New("duplicate reviewed capability")
		}
		route := definition.Method + " " + definition.Path
		if _, duplicate := routes[route]; duplicate {
			return errors.New("duplicate reviewed capability route")
		}
		names[definition.Name] = struct{}{}
		routes[route] = struct{}{}
	}
	return nil
}

func init() {
	if len(definitions) != 70 {
		panic("reviewed Hunter capability catalog must contain exactly 70 tools")
	}
	if err := Validate(definitions); err != nil {
		panic(err)
	}
}
