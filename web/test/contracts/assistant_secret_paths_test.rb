require "minitest/autorun"
require "pathname"
require "yaml"

class AssistantSecretPathsTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  COMPOSE_FILES = %w[docker-compose.yaml docker-compose.prod.yaml].freeze

  REMOVED_SERVICES = %w[
    assistant-egress assistant-events
    assistant-secrets-init assistant-token-init assistant-rabbitmq-init
  ].freeze
  PROVIDER_KEY_ENV = %w[ASSISTANT_ANTHROPIC_API_KEY ASSISTANT_OPENAI_API_KEY].freeze
  SECRET_FREE_SERVICES = %w[runner ansible-executor].freeze

  # Every Assistant secret is now a plain environment variable — either
  # substituted from the top-level .env at Compose parse time or supplied by
  # the deploy host — never a Compose file-backed secret, never a shared
  # volume, never a bind-mounted directory.
  MACHINE_SECRETS = %w[
    ASSISTANT_GATEWAY_MCP_TOKEN ASSISTANT_MCP_HUNTER_TOKEN
    ASSISTANT_GATEWAY_INGRESS_TOKEN ASSISTANT_VALIDATOR_INGRESS_TOKEN
  ].freeze

  def test_the_retired_services_and_volume_are_gone
    each_compose do |name, config|
      REMOVED_SERVICES.each do |service|
        refute config.fetch("services").key?(service), "#{name} still defines #{service}"
      end
      refute (config["volumes"] || {}).key?("assistant_secrets"), "#{name} still defines assistant_secrets"
      config.fetch("services").each do |service_name, service|
        Array(service["volumes"]).each do |mount|
          refute_includes mount.to_s, "/run/secrets", "#{name}: #{service_name} still mounts /run/secrets"
          refute_includes mount.to_s, "/run/assistant/secrets", "#{name}: #{service_name} still mounts the retired volume"
        end
      end
    end
  end

  def test_provider_keys_never_reach_the_execution_services
    each_compose do |name, config|
      SECRET_FREE_SERVICES.each do |service_name|
        service = config.fetch("services")[service_name]
        next unless service

        environment = service.fetch("environment", {})
        keys = environment.is_a?(Hash) ? environment.keys : environment.map { |e| e.split("=").first }
        PROVIDER_KEY_ENV.each do |secret|
          refute_includes keys, secret, "#{name}: #{service_name} receives #{secret}"
        end
      end
    end
  end

  # F7/binding ruling: `environment:` alone is a false-negative guarantee.
  # Dev `runner` used to carry `env_file: ['.env']`, and .env also holds the
  # two provider keys, so ANY key placed in .env would have reached the
  # runner container regardless of what its `environment:` block declared.
  # Both execution services must therefore also carry no `env_file:` at all —
  # matching production, which never used one.
  def test_neither_execution_service_reads_the_shared_env_file
    each_compose do |name, config|
      SECRET_FREE_SERVICES.each do |service_name|
        service = config.fetch("services")[service_name]
        next unless service

        refute service.key?("env_file"), "#{name}: #{service_name} still reads env_file, which also carries .env's provider keys"
      end
    end
  end

  def test_no_assistant_service_is_profile_gated
    each_compose_body do |name, body|
      refute_includes body, 'profiles: ["assistant"]',
        "#{name} still hides assistant services behind a Compose profile"
    end
  end

  # None of the six retired machine credentials survive as Compose secrets or
  # Docker-volume-backed files: the four bearer tokens (gateway MCP, hunter
  # token, gateway ingress, validator ingress) are plain environment
  # variables now, and the two RabbitMQ-only credentials (the AMQP passwords
  # and the provisioning password) have no replacement — the broker is gone.
  def test_every_machine_secret_is_environment_supplied_not_file_backed
    each_compose_body do |name, body|
      refute_match(/^\s*secrets:\s*$/, body, "#{name} still declares top-level Compose secrets")

      MACHINE_SECRETS.each do |secret|
        assert_includes body, "${#{secret}}", "#{name} does not substitute #{secret} from the environment"
      end
    end

    each_compose do |name, config|
      MACHINE_SECRETS.each do |secret|
        %w[assistant-gateway hunter-mcp assistant-validator web].each do |service_name|
          service = config.fetch("services")[service_name]
          next unless service

          environment = service.fetch("environment", {})
          next unless environment.is_a?(Hash)

          value = environment[secret]
          next if value.nil?

          assert_match(/\$\{#{Regexp.escape(secret)}(:-|\})/, value.to_s,
            "#{name}: #{service_name} does not source #{secret} from the environment")
        end
      end
    end
  end

  # Task 5 turns ASSISTANT_ENABLED into a kill override: any non-empty "false" forces
  # the assistant off regardless of installed keys. A baked-in Compose default of
  # `${ASSISTANT_ENABLED:-false}` would set that variable on every service and make
  # the whole zero-step-activation plan a no-op, so the variable must be unset unless
  # an operator (or their .env) explicitly sets it.
  def test_assistant_enabled_has_no_baked_in_default
    each_compose_body do |name, body|
      refute_match(/ASSISTANT_ENABLED:\s*\$\{ASSISTANT_ENABLED/, body,
        "#{name} still assigns ASSISTANT_ENABLED a baked-in default")
    end

    each_compose do |name, config|
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

  # config/master.key is gitignored but was not .dockerignore'd, so `COPY web/ ./`
  # baked a developer's key into the image as root:root 0600 — while CI, cloning
  # fresh, never has the file and so never produced such an image. Rails 8.1
  # consults Rails.application.credentials *before* the development
  # generate_local_secret fallback (railties configuration.rb#secret_key_base), so
  # merely having the file present makes every Assistant service that boots Rails
  # as `user: 1000:1000` die in Errno::EACCES on it. `web` runs as root over a bind
  # mount of the host tree in dev, so it escapes this failure mode either way.
  # Nothing in the app reads Rails credentials, and production supplies
  # SECRET_KEY_BASE from the environment, so the key belongs nowhere near the
  # build context.
  LOCAL_SECRET_PATHS = %w[web/config/master.key].freeze

  def test_the_build_context_excludes_rails_local_secrets
    patterns = ROOT.join(".dockerignore").each_line.map(&:strip)
      .reject { |line| line.empty? || line.start_with?("#") }

    LOCAL_SECRET_PATHS.each do |path|
      assert docker_context_excludes?(patterns, path),
        ".dockerignore does not exclude #{path}, so `COPY web/ ./` bakes it into the image"
    end
  end

  # Mirrors Docker's rule that the last matching pattern wins and a leading `!`
  # re-includes a path an earlier broader pattern excluded.
  def docker_context_excludes?(patterns, path)
    excluded = false
    patterns.each do |pattern|
      negated = pattern.start_with?("!")
      bare = negated ? pattern[1..] : pattern
      matches = File.fnmatch?(bare, path, File::FNM_PATHNAME) ||
        path.start_with?("#{bare.chomp('/')}/")
      excluded = !negated if matches
    end
    excluded
  end

  private

  def each_compose
    COMPOSE_FILES.each do |filename|
      config = YAML.safe_load_file(ROOT.join(filename), aliases: true)
      yield filename, config
    end
  end

  def each_compose_body
    COMPOSE_FILES.each do |filename|
      yield filename, ROOT.join(filename).read
    end
  end
end
