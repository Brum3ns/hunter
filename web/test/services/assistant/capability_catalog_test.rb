require "test_helper"
require "tempfile"

class Assistant::CapabilityCatalogTest < Minitest::Test
  APPROVED_OPERATIONAL_TOOLS = %w[
    list_hunter_capabilities
    list_targets get_target analyze_targets
    list_endpoints get_endpoint analyze_endpoints
    list_programs get_program analyze_programs list_program_changes
    list_scope_runs get_scope_run
    list_cves get_cve list_new_cves analyze_cves
    list_vulnerabilities get_vulnerability analyze_vulnerabilities
    create_vulnerability update_vulnerability
    list_templates get_template analyze_templates validate_whiterabbit_template
    validate_whiterabbit_yaml create_whiterabbit_template
    edit_whiterabbit_template
    list_jobs get_job analyze_jobs resolve_job_targets submit_whiterabbit_job
    get_control_center_health get_control_center_stats
    list_ansible_credential_metadata get_ansible_credential_metadata
    list_playbooks get_playbook analyze_playbooks validate_ansible_playbook
    export_ansible_playbooks create_ansible_playbook edit_ansible_playbook
    list_ansible_inventories get_ansible_inventory validate_ansible_inventory
    create_ansible_inventory edit_ansible_inventory queue_inventory_syntax_check
    queue_host_key_scan confirm_inventory_host_keys
    queue_inventory_connectivity_test get_inventory_utility_task
    list_ansible_variable_sets get_ansible_variable_set
    create_ansible_variable_set edit_ansible_variable_set
    create_nonsecret_ansible_variable edit_nonsecret_ansible_variable
    list_run_groups get_run_group analyze_ansible_runs
    launch_ansible_run_group cancel_ansible_run_group get_run cancel_ansible_run
    list_run_events get_ansible_executor_health
  ].freeze

  def test_default_catalog_contains_every_approved_operational_tool
    names = Assistant::CapabilityCatalog.load.tools.map { |tool| tool.fetch("name") }

    assert_equal APPROVED_OPERATIONAL_TOOLS.sort, names.sort
    assert_equal 70, names.length
  end

  def test_default_catalog_classifies_every_current_api_operation
    catalog = Assistant::CapabilityCatalog.load

    assert Assistant::CapabilityCoverage.verify!(
      catalog: catalog,
      route_operations: Assistant::CapabilityCoverage.route_operations,
      openapi_operations: Assistant::CapabilityCoverage.openapi_operations
    )
  end

  def test_loads_a_closed_operational_capability
    with_catalog(valid_catalog) do |path|
      catalog = Assistant::CapabilityCatalog.load(path: path)
      tool = catalog.tool!("list_targets")

      assert_equal 1, catalog.version
      assert_equal "targets", tool.fetch("module")
      assert_equal "targets_read", tool.fetch("scope")
      assert_equal [ "list_targets" ], catalog.tools.map { |entry| entry.fetch("name") }
    end
  end

  def test_rejects_wildcard_scopes
    document = valid_catalog
    document["tools"][0]["scope"] = "*"

    error = assert_raises(Assistant::CapabilityCatalog::InvalidCatalog) do
      with_catalog(document) { |path| Assistant::CapabilityCatalog.load(path: path) }
    end

    assert_equal "tools[0].scope must be an exact non-wildcard scope", error.message
  end

  def test_rejects_generic_operational_tools
    document = valid_catalog
    document["tools"][0]["name"] = "execute"

    error = assert_raises(Assistant::CapabilityCatalog::InvalidCatalog) do
      with_catalog(document) { |path| Assistant::CapabilityCatalog.load(path: path) }
    end

    assert_equal "tools[0].name is a prohibited generic capability", error.message
  end

  def test_rejects_enabled_tools_that_can_receive_secrets
    document = valid_catalog
    document["tools"][0]["secret_input"] = "allowed"

    error = assert_raises(Assistant::CapabilityCatalog::InvalidCatalog) do
      with_catalog(document) { |path| Assistant::CapabilityCatalog.load(path: path) }
    end

    assert_equal "tools[0] must deny secret input and output", error.message
  end

  def test_rejects_unknown_tool_metadata
    document = valid_catalog
    document["tools"][0]["authority"] = "admin"

    error = assert_raises(Assistant::CapabilityCatalog::InvalidCatalog) do
      with_catalog(document) { |path| Assistant::CapabilityCatalog.load(path: path) }
    end

    assert_equal "tools[0] has unknown keys: authority", error.message
  end

  def test_rejects_duplicate_tool_names
    document = valid_catalog
    document["tools"] << document["tools"][0].deep_dup

    error = assert_raises(Assistant::CapabilityCatalog::InvalidCatalog) do
      with_catalog(document) { |path| Assistant::CapabilityCatalog.load(path: path) }
    end

    assert_equal "duplicate tool name: list_targets", error.message
  end

  private

  def valid_catalog
    {
      "version" => 1,
      "tools" => [
        {
          "name" => "list_targets",
          "module" => "targets",
          "operation" => "list",
          "effect" => "read",
          "scope" => "targets_read",
          "input_schema_version" => 1,
          "output_schema_version" => 1,
          "machine_method" => "GET",
          "machine_path" => "/api/v1/assistant/machine/targets",
          "api_operation" => "GET /api/v1/targets",
          "gate" => "targets",
          "rate_profile" => "read",
          "byte_profile" => "standard",
          "idempotency" => "none",
          "locking" => "none",
          "secret_input" => "deny",
          "secret_output" => "deny",
          "audit_event" => "assistant.machine.targets.list",
          "target_metadata" => [ "query" ],
          "rollout" => "enabled"
        }
      ],
      "api_classifications" => {
        "GET /api/v1/targets" => {
          "classification" => "enabled",
          "tool" => "list_targets"
        }
      }
    }
  end

  def with_catalog(document)
    Tempfile.create([ "assistant-capabilities", ".yml" ]) do |file|
      file.write(document.to_yaml)
      file.flush
      yield file.path
    end
  end
end
