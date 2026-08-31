require "minitest/autorun"
require "open3"
require "pathname"

class AssistantReleaseGateTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  SCRIPTS = %w[
    ops/assistant/verify_compose_security.sh
    ops/assistant/test_network_denials.sh
    ops/assistant/check_secret_leaks.sh
  ].freeze

  def test_release_gate_scripts_are_executable_and_shell_valid
    SCRIPTS.each do |relative_path|
      path = ROOT.join(relative_path)
      assert path.executable?, "#{relative_path} is not executable"
      _output, error, status = Open3.capture3("sh", "-n", path.to_s)
      assert status.success?, "#{relative_path}: #{error}"
    end
  end

  def test_network_gate_has_positive_controls_and_dns_and_direct_ip_denials
    script = ROOT.join("ops/assistant/test_network_denials.sh").read

    assert_includes script, "assert_connects"
    assert_includes script, "assert_denied_host"
    assert_includes script, "service_addresses"
    assert_includes script, "169.254.169.254"
    assert_includes script, "hunter-mcp"
    assert_includes script, "assistant-codex"
    assert_includes script, "assistant-claude"
    assert_includes script, "assert_connects assistant-codex hunter-mcp 8080"
    assert_includes script, "assert_connects assistant-claude hunter-mcp 8080"
    assert_includes script, "assert_host_mcp_listener_if_reachable"
  end

  def test_compose_security_gate_checks_active_direct_seccomp_profiles
    script = ROOT.join("ops/assistant/verify_compose_security.sh").read

    assert_includes script, '"assistant-codex" => "codex"'
    assert_includes script, '"assistant-claude" => "claude"'
    assert_includes script, '"hunter-mcp" => "mcp"'
    assert_includes script, 'HUNTER_ASSISTANT_MCP_BIND_IP'
    assert_includes script, 'HUNTER_ASSISTANT_MCP_PORT'
    assert_includes script, 'hunter-mcp must publish exactly one TCP listener'
  end

  def test_secret_gate_does_not_print_secret_values
    secret_gate = ROOT.join("ops/assistant/check_secret_leaks.sh").read

    assert_includes secret_gate, "gitleaks git --redact"
    assert_includes secret_gate, "git rev-list --all"
    assert_includes secret_gate, "docker compose logs --no-color"
    assert_includes secret_gate, "docker image save"
    assert_includes secret_gate, "assistant-codex"
    assert_includes secret_gate, "assistant-claude"
    refute_match(/cat\s+.*secret/i, secret_gate)
  end

  def test_ci_runs_dependency_image_sbom_and_secret_gates
    workflow = ROOT.join(".gitea/workflows/build.yml").read

    %w[govulncheck brakeman bundle-audit gitleaks syft grype CycloneDX SPDX].each do |gate|
      assert_includes workflow, gate
    end
    assert_includes workflow, "check_secret_leaks.sh"
    assert_includes workflow, "test_network_denials.sh"
    assert_includes workflow, "ASSISTANT_CODEX_IMAGE"
    assert_includes workflow, "ASSISTANT_CLAUDE_IMAGE"
    assert_includes workflow, "context: assistant/codex"
    assert_includes workflow, "context: assistant/claude"
    assert_includes workflow, "assistant/codex assistant/claude assistant/gateway assistant/mcp assistant/validator"
    assert_includes workflow, "@openai/codex@0.144.4"
    assert_includes workflow, "TestRealCodex(EnforcesApprovedHunterMCPBoundary|ApplyPatchCannotMutateReadOnlyWorkspace)"
  end

  def test_project_context_and_production_checklist_record_the_enablement_boundary
    agents = ROOT.join("AGENTS.md").read
    checklist = ROOT.join("docs/security/hunter-assistant-production-checklist.md").read
    direct_runbook = ROOT.join("docs/runbooks/assistant-codex-mcp-smoke-test.md").read

    assert_includes agents, "## Assistant capability change rule"
    assert_includes agents, "approved threat-model delta"
    assert_includes agents, "Wildcard scopes"
    assert_includes agents, "Unrestricted Whiterabbit command authoring and execution"
    assert_includes checklist, "Unrestricted Whiterabbit command authoring and execution"
    assert_includes checklist, "arbitrary worker execution"

    %w[
      Reviewer
      retention
      digest
      SBOM
      scan
      rotation
      ASSISTANT_ENABLED=false
      enable decision
      assistant-codex
      assistant-claude
      immutable-workspace
      legacy_provider_retired
      metadata-only
    ].each do |term|
      assert_includes checklist, term
    end

    %w[
      codex-cli\ 0.144.4
      codex\ login\ --device-auth
      claude\ login
      tool_search
      forbidden.txt
      legacy-gateway
      ASSISTANT_ENABLED=false
    ].each do |term|
      assert_includes direct_runbook, term.tr("\\", "")
    end
    assert_includes direct_runbook, "Never run `docker compose down -v`"
  end

  def test_token_only_external_mcp_risk_and_operator_path_are_disclosed
    agents = ROOT.join("AGENTS.md").read
    checklist = ROOT.join("docs/security/hunter-assistant-production-checklist.md").read
    settings = ROOT.join("web/app/views/settings/_assistant.html.erb").read
    runbook = ROOT.join("docs/runbooks/assistant-codex-mcp-smoke-test.md").read
    broker_readme = ROOT.join("assistant/mcp/README.md").read
    root_readme = ROOT.join("README.md").read

    assert_includes agents, "Token-only external Hunter MCP access"
    assert_includes agents, "2026-08-27-assistant-token-only-external-mcp-design.md"
    assert_includes checklist, "shared-client indistinguishability"
    assert_includes checklist, "shared token rotation impact"
    assert_includes settings, "full enabled operational catalog"
    assert_includes settings, "not bound to a prompt, turn, external client, or source IP"

    %w[HUNTER_MCP_TOKEN].each do |term|
      assert_includes runbook, term
    end
    assert_includes runbook, "codex mcp add hunter"
    assert_includes runbook, "codex mcp get hunter"
    assert_includes runbook, "codex mcp list"
    assert_includes runbook, "HUNTER_ASSISTANT_MCP_HUNTER_TOKEN"

    [ checklist, runbook, broker_readme, root_readme ].each do |document|
      assert_includes document, "token-only external MCP"
      assert_includes document, "loopback default"
      assert_includes document, "HTTPS or authenticated VPN"
      assert_includes document, "source-network firewall/proxy restriction"
    end
  end
end
