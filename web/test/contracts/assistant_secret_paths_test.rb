require "minitest/autorun"
require "pathname"
require "yaml"

class AssistantSecretPathsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  VOLUME_PATH = "/run/assistant/secrets".freeze
  MACHINE_SECRETS = %w[
    assistant_rails_amqp_password assistant_gateway_amqp_password
    assistant_validator_amqp_password assistant_rabbitmq_provision_password
    assistant_gateway_mcp_token assistant_mcp_hunter_token
  ].freeze

  def test_go_services_read_machine_credentials_from_the_volume
    %w[gateway mcp validator].each do |service|
      body = Dir.glob(ROOT.join("assistant/#{service}/internal/config/*.go"))
        .reject { |path| path.end_with?("_test.go") }
        .map { |path| File.read(path) }.join

      refute_match(%r{"/run/secrets/assistant_(rails|gateway|validator)_amqp_password"}, body,
        "#{service} still reads a machine credential from the Compose secret mount")
      assert_includes body, VOLUME_PATH, "#{service} does not read from #{VOLUME_PATH}"
    end
  end

  # The gateway resolves each catalog entry as
  # filepath.Join(defaultProviderSecretDir, file) rather than embedding a joined
  # literal (defaultProviderSecretDir is asserted separately, unchanged by this
  # task at "/run/secrets" — only the machine-credential paths move), so the
  # in-sync check is against the bare filename the map keys resolve through.
  def test_the_catalog_secret_file_matches_the_gateway_mapping
    catalog = YAML.safe_load_file(ROOT.join("web/config/assistant_provider_catalog.yml"), aliases: false)
    gateway = File.read(ROOT.join("assistant/gateway/internal/config/config.go"))

    assert_includes gateway, 'defaultProviderSecretDir = "/run/secrets"',
      "the gateway no longer resolves provider keys under /run/secrets"
    catalog.each_value do |entry|
      assert_includes gateway, "\"#{entry.fetch('secret_file')}\"",
        "the gateway does not read #{entry.fetch('secret_file')}"
    end
  end

  # The gateway accepts a 0600 key only when a write-open fails, proving the mount is
  # genuinely read-only (assistant/gateway/internal/config/config.go safeSecretMode).
  # Assistant::ProviderCredentials deliberately does not replicate that probe, so the
  # read-only mount is the contract that keeps the two in agreement. Losing `:ro` would
  # let Rails report a provider available that the gateway then refuses. web and
  # assistant-events also read this directory (Assistant::Config.enabled?), so the
  # same :ro requirement holds for them — checked per service, not as a body-wide
  # substring, so a service that mounts it writable is caught even if another
  # service still mounts it read-only.
  PROVIDER_SECRET_MOUNT_SERVICES = %w[assistant-gateway web assistant-events].freeze

  def test_the_provider_secret_mount_is_read_only
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      config = YAML.safe_load_file(ROOT.join(name), aliases: true)
      services = config.fetch("services")

      PROVIDER_SECRET_MOUNT_SERVICES.each do |service_name|
        mounts = services.fetch(service_name).fetch("volumes", [])

        assert_includes mounts, "./secrets:/run/secrets:ro",
          "#{name}: #{service_name} does not mount the provider secret directory read-only"
        refute_includes mounts, "./secrets:/run/secrets",
          "#{name}: #{service_name} mounts the provider secret directory writable"
      end
    end
  end

  def test_no_assistant_service_is_profile_gated
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read

      refute_includes body, 'profiles: ["assistant"]',
        "#{name} still hides assistant services behind a Compose profile"
    end
  end

  def test_every_machine_secret_is_volume_backed_not_file_backed
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read

      MACHINE_SECRETS.each do |secret|
        refute_match(/^  #{secret}:\n    file:/m, body,
          "#{name} still defines #{secret} as a file-backed Compose secret")
      end
      assert_includes body, "assistant_secrets:", "#{name} lacks the assistant secrets volume"
    end
  end

  # Task 5 turns ASSISTANT_ENABLED into a kill override: any non-empty "false" forces
  # the assistant off regardless of installed keys. A baked-in Compose default of
  # `${ASSISTANT_ENABLED:-false}` would set that variable on every service and make
  # the whole zero-step-activation plan a no-op, so the variable must be unset unless
  # an operator (or their .env) explicitly sets it.
  def test_assistant_enabled_has_no_baked_in_default
    %w[docker-compose.yaml docker-compose.prod.yaml].each do |name|
      body = ROOT.join(name).read
      refute_match(/ASSISTANT_ENABLED:\s*\$\{ASSISTANT_ENABLED/, body,
        "#{name} still assigns ASSISTANT_ENABLED a baked-in default")

      config = YAML.safe_load_file(ROOT.join(name), aliases: true)
      config.fetch("services").each do |service_name, service|
        environment = service.fetch("environment", {})
        next unless environment.is_a?(Hash)

        refute environment.key?("ASSISTANT_ENABLED"),
          "#{name}: #{service_name} assigns ASSISTANT_ENABLED a value"
      end
    end

    env_example = ROOT.join(".env.example").read
    refute_match(/^ASSISTANT_ENABLED=/, env_example,
      ".env.example still assigns ASSISTANT_ENABLED a default value")
    refute_match(/^ASSISTANT_SECRET_DIR=/, env_example,
      ".env.example still references the retired ASSISTANT_SECRET_DIR")
  end
end
