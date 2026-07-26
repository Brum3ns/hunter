require "base64"
require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "yaml"

class AssistantComposeTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  COMPOSE_FILES = %w[docker-compose.yaml docker-compose.prod.yaml].freeze
  ASSISTANT_SERVICES = %w[
    assistant-gateway
    hunter-mcp
    assistant-validator
    assistant-egress
    assistant-events
    assistant-rabbitmq-init
  ].freeze
  UNTRUSTED_SERVICES = %w[
    assistant-gateway
    hunter-mcp
    assistant-validator
    assistant-egress
  ].freeze
  # assistant-gateway reads the two provider-key files through a read-only bind
  # mount of the single host secrets/ directory instead of a file-backed Compose
  # secret, so a missing key is readable-as-absent rather than a fatal boot error.
  # hunter-mcp/assistant-validator/assistant-gateway also mount the bootstrap-
  # generated machine-credential volume read-only (assistant-egress needs neither).
  ALLOWED_HOST_MOUNTS = {
    "assistant-gateway" => %w[./secrets:/run/secrets:ro assistant_secrets:/run/assistant/secrets:ro],
    "hunter-mcp" => %w[assistant_secrets:/run/assistant/secrets:ro],
    "assistant-validator" => %w[assistant_secrets:/run/assistant/secrets:ro]
  }.freeze
  NETWORKS = {
    "web" => %w[default assistant-queue assistant-mcp-rails],
    "rabbitmq" => %w[default assistant-queue assistant-gateway-queue assistant-validator-queue],
    "assistant-gateway" => %w[assistant-gateway-queue assistant-gateway-mcp assistant-egress-in],
    "hunter-mcp" => %w[assistant-gateway-mcp assistant-mcp-rails],
    "assistant-validator" => %w[assistant-validator-queue],
    "assistant-egress" => %w[assistant-egress-in assistant-egress-out],
    "assistant-events" => %w[default assistant-queue assistant-mcp-rails],
    "assistant-rabbitmq-init" => %w[assistant-queue]
  }.freeze
  # Every consumer of the bootstrap-generated machine-credential volume mounts
  # it read-only; assistant-bootstrap is the sole read-write writer.
  ASSISTANT_SECRETS_VOLUME_RO = %w[
    web
    rabbitmq
    assistant-gateway
    hunter-mcp
    assistant-validator
    assistant-events
    assistant-rabbitmq-init
  ].freeze

  def test_both_compose_definitions_isolate_and_harden_assistant_services
    each_compose do |filename, config|
      services = config.fetch("services")
      networks = config.fetch("networks")

      ASSISTANT_SERVICES.each do |name|
        assert services.key?(name), "#{filename}: missing #{name}"
        assert_empty services.fetch(name).fetch("ports", []), "#{filename}: #{name} publishes a port"
        assert_empty services.fetch(name).fetch("profiles", []),
          "#{filename}: #{name} still starts only under a Compose profile"
      end
      assert_equal "on-failure:3", services.fetch("assistant-rabbitmq-init").fetch("restart")

      UNTRUSTED_SERVICES.each do |name|
        service = services.fetch(name)
        assert_equal true, service["read_only"], "#{filename}: #{name} root is writable"
        assert_equal [ "ALL" ], service.fetch("cap_drop"), "#{filename}: #{name} retains capabilities"
        assert_equal true, service["init"], "#{filename}: #{name} has no init"
        assert_equal "unless-stopped", service["restart"], "#{filename}: #{name} restart policy"
        assert_positive_numeric_user(filename, name, service.fetch("user"))
        assert_security_options(filename, name, service.fetch("security_opt"))
        assert_bounded_tmpfs(filename, name, service.fetch("tmpfs"))
        refute service["mem_limit"].to_s.empty?, "#{filename}: #{name} has no memory limit"
        refute service["cpus"].to_s.empty?, "#{filename}: #{name} has no CPU limit"
        assert_operator service.fetch("pids_limit").to_i, :>, 0, "#{filename}: #{name} has no PID limit"
        assert service["healthcheck"].is_a?(Hash), "#{filename}: #{name} has no health check"
        assert_equal ALLOWED_HOST_MOUNTS.fetch(name, []), service.fetch("volumes", []),
          "#{filename}: #{name} has an unexpected host mount"
        refute service["privileged"], "#{filename}: #{name} is privileged"
        refute_equal "host", service["network_mode"], "#{filename}: #{name} uses host networking"
        refute_equal "host", service["pid"], "#{filename}: #{name} uses host PID"
        refute_equal "host", service["ipc"], "#{filename}: #{name} uses host IPC"
        assert_empty service.fetch("devices", []), "#{filename}: #{name} has a device"
      end

      NETWORKS.each do |service_name, expected|
        assert_equal expected.sort, service_networks(services.fetch(service_name)).sort,
          "#{filename}: #{service_name} network membership"
      end

      %w[
        assistant-queue
        assistant-gateway-queue
        assistant-gateway-mcp
        assistant-mcp-rails
        assistant-validator-queue
        assistant-egress-in
      ].each do |network|
        assert_equal true, networks.fetch(network)["internal"], "#{filename}: #{network} is externally routed"
      end
      refute networks.fetch("assistant-egress-out").fetch("internal", false),
        "#{filename}: egress proxy has no outbound network"

      gateway_networks = service_networks(services.fetch("assistant-gateway"))
      %w[web db mongo runner ansible-executor].each do |forbidden_peer|
        shared = gateway_networks & service_networks(services.fetch(forbidden_peer))
        assert_empty shared,
          "#{filename}: assistant-gateway shares #{shared.join(', ')} with #{forbidden_peer}"
      end
    end
  end

  # No service declares a Compose file-backed secret any more: the six machine
  # credentials moved to the assistant_secrets volume (Task 9), and the two
  # provider keys were never Compose secrets (bind-mounted directly instead).
  def test_no_compose_service_declares_a_file_backed_secret
    each_compose do |filename, config|
      refute config.key?("secrets"), "#{filename}: still declares top-level Compose secrets"

      config.fetch("services").each do |service_name, service|
        assert_empty service_secrets(service), "#{filename}: #{service_name} still mounts a file-backed secret"
      end
    end
  end

  def test_assistant_secrets_volume_is_mounted_read_only_except_by_bootstrap
    each_compose do |filename, config|
      services = config.fetch("services")

      ASSISTANT_SECRETS_VOLUME_RO.each do |name|
        mounts = services.fetch(name).fetch("volumes", [])
        assert_includes mounts, "assistant_secrets:/run/assistant/secrets:ro",
          "#{filename}: #{name} does not mount the assistant secrets volume read-only"
      end

      bootstrap_mounts = services.fetch("assistant-bootstrap").fetch("volumes", [])
      assert_includes bootstrap_mounts, "assistant_secrets:/run/assistant/secrets",
        "#{filename}: assistant-bootstrap does not mount the assistant secrets volume"
      refute_includes bootstrap_mounts, "assistant_secrets:/run/assistant/secrets:ro",
        "#{filename}: assistant-bootstrap mounts its own secrets volume read-only"

      services.each do |name, service|
        next if ASSISTANT_SECRETS_VOLUME_RO.include?(name) || name == "assistant-bootstrap"

        refute service.fetch("volumes", []).any? { |mount| mount.start_with?("assistant_secrets:") },
          "#{filename}: #{name} unexpectedly mounts the assistant secrets volume"
      end
    end
  end

  # Task 5 makes ASSISTANT_ENABLED a kill override, so no service may bake in a
  # default value for it (see assistant_secret_paths_test.rb for the full
  # rationale); this only re-checks it is absent from these three services'
  # environment blocks entirely, which used to hold `${ASSISTANT_ENABLED:-false}`.
  def test_assistant_is_not_forced_off_by_default_in_either_compose_definition
    each_compose do |filename, config|
      %w[web rabbitmq assistant-events].each do |name|
        refute config.fetch("services").fetch(name).fetch("environment", {}).key?("ASSISTANT_ENABLED"),
          "#{filename}: #{name} bakes in a value for ASSISTANT_ENABLED"
      end
    end
  end

  def test_assistant_bootstrap_is_hardened_like_its_siblings_and_gates_its_dependents
    each_compose do |filename, config|
      services = config.fetch("services")
      bootstrap = services.fetch("assistant-bootstrap")

      assert_empty bootstrap.fetch("ports", []), "#{filename}: assistant-bootstrap publishes a port"
      assert_equal true, bootstrap["read_only"], "#{filename}: assistant-bootstrap root is writable"
      assert_equal [ "ALL" ], bootstrap.fetch("cap_drop"), "#{filename}: assistant-bootstrap retains capabilities"
      assert_equal "no", bootstrap["restart"], "#{filename}: assistant-bootstrap has a restart policy"
      assert_positive_numeric_user(filename, "assistant-bootstrap", bootstrap.fetch("user"))
      assert_includes bootstrap.fetch("security_opt"), "no-new-privileges:true",
        "#{filename}: assistant-bootstrap allows privilege escalation"
      refute_empty bootstrap.fetch("tmpfs"), "#{filename}: assistant-bootstrap has no tmpfs"
      assert_operator bootstrap.fetch("pids_limit").to_i, :>, 0, "#{filename}: assistant-bootstrap has no PID limit"

      assert_equal({ "condition" => "service_healthy" }, bootstrap.fetch("depends_on").fetch("web"),
        "#{filename}: assistant-bootstrap does not gate on web's health")
      refute services.fetch("web").fetch("depends_on", {}).key?("assistant-bootstrap"),
        "#{filename}: web depends on assistant-bootstrap, which would be circular"

      %w[assistant-rabbitmq-init hunter-mcp assistant-gateway assistant-validator assistant-events].each do |name|
        assert_equal({ "condition" => "service_completed_successfully" },
          services.fetch(name).fetch("depends_on").fetch("assistant-bootstrap"),
          "#{filename}: #{name} does not wait for assistant-bootstrap to complete")
      end
    end
  end

  def test_service_specific_mandatory_access_profiles_default_deny_dangerous_operations
    profiles = {
      "gateway" => "hunter-assistant-gateway",
      "mcp" => "hunter-mcp",
      "validator" => "hunter-assistant-validator",
      "egress" => "hunter-assistant-egress"
    }

    profiles.each do |service, apparmor_name|
      seccomp = JSON.parse(ROOT.join("ops/assistant/seccomp/#{service}.json").read)
      assert_equal "SCMP_ACT_ERRNO", seccomp.fetch("defaultAction")
      allowed = seccomp.fetch("syscalls")
        .select { |rule| rule.fetch("action") == "SCMP_ACT_ALLOW" }
        .flat_map { |rule| rule.fetch("names") }
      %w[mount umount2 ptrace unshare keyctl bpf init_module finit_module kexec_load].each do |syscall|
        refute_includes allowed, syscall, "#{service} seccomp permits #{syscall}"
      end
      socket_rules = seccomp.fetch("syscalls").select { |rule| rule.fetch("names").include?("socket") }
      refute_empty socket_rules, "#{service} seccomp has no bounded socket rule"
      assert socket_rules.all? { |rule| rule.fetch("args").length >= 2 },
        "#{service} seccomp has an unbounded socket rule"

      apparmor = ROOT.join("ops/assistant/apparmor/#{apparmor_name}").read
      assert_includes apparmor, "profile #{apparmor_name}"
      assert_includes apparmor, "deny mount"
      assert_includes apparmor, "deny ptrace"
      assert_includes apparmor, "deny network raw"
      assert_includes apparmor, "/dev/init rix,"
    end
  end

  def test_ci_publishes_immutable_commit_tags_for_every_assistant_image
    workflow = ROOT.join(".gitea/workflows/build.yml").read
    %w[
      ASSISTANT_GATEWAY_IMAGE
      ASSISTANT_MCP_IMAGE
      ASSISTANT_VALIDATOR_IMAGE
      ASSISTANT_EGRESS_IMAGE
      ASSISTANT_RABBITMQ_IMAGE
    ].each do |image|
      assert_includes workflow, "${{ env.#{image} }}:${{ gitea.sha }}"
    end
  end

  def test_local_credentials_are_excluded_from_every_root_image_build_context
    dockerignore = ROOT.join(".dockerignore").read.lines.map(&:strip)
    assert_includes dockerignore, ".env"
    assert_includes dockerignore, ".env.*"
    assert_includes dockerignore, "secrets/dev"
    assert_includes dockerignore, "secrets/prod"
  end

  def test_hardening_directives_match_between_both_compose_files
    counts = %w[docker-compose.yaml docker-compose.prod.yaml].map do |name|
      body = ROOT.join(name).read
      %w[read_only security_opt cap_drop no-new-privileges tmpfs pids_limit].to_h do |directive|
        [ directive, body.scan(directive).length ]
      end
    end

    assert_equal counts.first, counts.last,
      "the compose files have diverged in runtime hardening"
  end

  def test_rabbitmq_bootstrap_preserves_hunter_user_without_plaintext_definitions
    entrypoint = ROOT.join("ops/assistant/rabbitmq/entrypoint.sh").read
    dockerfile = ROOT.join("ops/assistant/rabbitmq/Dockerfile").read
    provisioner = ROOT.join("ops/assistant/provision_rabbitmq.rb").read

    assert_includes entrypoint, "assistant_topology_complete"
    assert_includes entrypoint, "rabbitmqctl import_definitions"
    assert_includes entrypoint, "ASSISTANT_RABBITMQ_REPROVISION"
    assert_includes entrypoint, "list_permissions"
    assert_includes entrypoint, "list_exchanges"
    assert_includes entrypoint, "list_queues"
    assert_includes entrypoint, "list_bindings"
    assert_includes entrypoint, "trace_off -p /hunter-assistant"
    refute_match(/trace_off -p \/hunter-assistant.*\|\| true/, entrypoint)
    assert_includes entrypoint, "watchdog_pid"
    assert_includes entrypoint, "sleep 120"
    assert_includes entrypoint, "password_hash"
    refute_includes entrypoint, '\\"password\\":'
    refute_includes entrypoint, "definitions.import_backend"
    refute_includes entrypoint, "management.load_definitions"
    assert_includes provisioner, 'delete("/api/users/#{escape(@admin_user)}")'
    refute_match(/ensure\s+delete_provisioner/m, provisioner)
    assert_includes dockerfile, "apt-get install --no-install-recommends -y jq"

    each_compose do |filename, config|
      value = config.fetch("services").fetch("rabbitmq")
        .fetch("environment").fetch("ASSISTANT_RABBITMQ_REPROVISION")
      assert_includes value.to_s, ":-false", "#{filename}: reprovision is on by default"
    end
  end

  def test_rabbitmq_password_hasher_implements_the_documented_salted_sha256_format
    secret = "a-local-test-value"
    script = ROOT.join("ops/assistant/rabbitmq/hash_password.sh")
    output, error, status = Open3.capture3(script.to_s, stdin_data: secret)

    assert status.success?, error
    decoded = Base64.strict_decode64(output.strip)
    assert_equal 36, decoded.bytesize
    salt = decoded.byteslice(0, 4)
    assert_equal Digest::SHA256.digest(salt + secret), decoded.byteslice(4, 32)
  end

  def test_both_compose_files_read_provider_keys_from_the_single_secret_directory
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read

      assert_includes body, "- ./secrets:/run/secrets:ro",
        "#{name} does not bind-mount the secret directory read-only"
      refute_match(/secrets\/(dev|prod)\b/, body,
        "#{name} still references a per-environment secret directory")
      refute_match(/^  assistant_(openai|anthropic)_api_key:/m, body,
        "#{name} still defines a provider key as a file-backed Compose secret")
    end
  end

  def test_git_ignores_secret_material_but_keeps_documentation
    ignored = ROOT.join(".gitignore").read

    assert_includes ignored, "/secrets/*"
    assert_includes ignored, "!/secrets/.keep"
    assert_includes ignored, "!/secrets/README.md"
    assert_includes ignored, "!/secrets/examples/"
  end

  private

  def each_compose
    COMPOSE_FILES.each do |filename|
      config = YAML.safe_load_file(ROOT.join(filename), aliases: true)
      yield filename, config
    end
  end

  def service_networks(service)
    networks = service.fetch("networks", [ "default" ])
    networks.is_a?(Hash) ? networks.keys : networks
  end

  def service_secrets(service)
    service.fetch("secrets", []).map do |secret|
      secret.is_a?(Hash) ? secret.fetch("source") : secret
    end
  end

  def assert_positive_numeric_user(filename, name, user)
    uid, gid = user.to_s.split(":", 2)
    assert_match(/\A\d+\z/, uid, "#{filename}: #{name} user is not numeric")
    assert_match(/\A\d+\z/, gid, "#{filename}: #{name} group is not numeric")
    assert_operator uid.to_i, :>, 0, "#{filename}: #{name} runs as root"
    assert_operator gid.to_i, :>, 0, "#{filename}: #{name} runs with root group"
  end

  def assert_security_options(filename, name, options)
    assert_includes options, "no-new-privileges:true", "#{filename}: #{name} allows privilege escalation"
    assert options.any? { |option| option.start_with?("seccomp=") }, "#{filename}: #{name} has no seccomp profile"
    assert options.any? { |option| option.start_with?("apparmor=") }, "#{filename}: #{name} has no AppArmor profile"
  end

  def assert_bounded_tmpfs(filename, name, mounts)
    refute_empty mounts, "#{filename}: #{name} has no tmpfs"
    mounts.each do |mount|
      %w[noexec nosuid nodev size=].each do |option|
        assert_includes mount, option, "#{filename}: #{name} tmpfs is missing #{option}"
      end
    end
  end
end
