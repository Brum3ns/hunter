require "json"
require "minitest/autorun"
require "pathname"
require "yaml"

class AssistantComposeTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  COMPOSE_FILES = %w[docker-compose.yaml docker-compose.prod.yaml].freeze
  # The RabbitMQ broker, the squid egress proxy, the Rails event consumer and
  # the three bootstrap one-shots are gone: every secret is now a plain
  # environment variable and `web` talks to the gateway/validator over direct
  # HTTP. The direct Claude and Codex runners remain in the Assistant's own
  # trust boundary alongside the legacy services.
  ASSISTANT_SERVICES = %w[
    assistant-gateway
    hunter-mcp
    assistant-validator
    assistant-claude
    assistant-codex
  ].freeze
  UNTRUSTED_SERVICES = ASSISTANT_SERVICES
  # The legacy provider-gateway path is retired from the default stack: these two
  # services stay hardened and defined, but sit behind the `legacy-gateway`
  # Compose profile so a default `up` no longer starts them. The Assistant now
  # runs chat through the Claude Code service instead.
  LEGACY_PROFILE_SERVICES = %w[assistant-gateway assistant-validator].freeze
  # No Assistant service bind-mounts anything from the host any more: the two
  # provider keys and all four machine tokens arrive as environment variables,
  # so `volumes:` is empty for every one of them — except assistant-claude,
  # whose subscription login/session must survive a restart and so lives on a
  # dedicated *named volume* (not a host bind mount).
  ALLOWED_HOST_MOUNTS = {
    "assistant-claude" => [ "assistant_claude_home:/home/claude" ],
    "assistant-codex" => [ "assistant_codex_home:/home/codex/.codex" ]
  }.freeze
  NETWORKS = {
    "web" => %w[default assistant-rails-gateway assistant-rails-validator assistant-mcp-rails assistant-rails-claude assistant-rails-codex],
    "assistant-gateway" => %w[assistant-rails-gateway assistant-gateway-mcp assistant-gateway-egress],
    "hunter-mcp" => %w[assistant-gateway-mcp assistant-mcp-rails assistant-claude-mcp assistant-codex-mcp],
    "assistant-validator" => %w[assistant-rails-validator],
    "assistant-claude" => %w[assistant-rails-claude assistant-claude-egress assistant-claude-mcp],
    "assistant-codex" => %w[assistant-rails-codex assistant-codex-egress assistant-codex-mcp]
  }.freeze
  # Per-service runtime hardening, compared key-by-key between the two files.
  HARDENING_KEYS = %w[
    read_only cap_drop security_opt tmpfs pids_limit mem_limit cpus user init privileged
  ].freeze

  def test_both_compose_definitions_isolate_and_harden_assistant_services
    each_compose do |filename, config|
      services = config.fetch("services")
      networks = config.fetch("networks")

      ASSISTANT_SERVICES.each do |name|
        assert services.key?(name), "#{filename}: missing #{name}"
        assert_empty services.fetch(name).fetch("ports", []), "#{filename}: #{name} publishes a port"
        expected_profiles = LEGACY_PROFILE_SERVICES.include?(name) ? [ "legacy-gateway" ] : []
        assert_equal expected_profiles, services.fetch(name).fetch("profiles", []),
          "#{filename}: #{name} has unexpected Compose profile placement"
      end

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
        assistant-rails-gateway
        assistant-rails-validator
        assistant-gateway-mcp
        assistant-mcp-rails
        assistant-rails-claude
        assistant-claude-mcp
        assistant-rails-codex
        assistant-codex-mcp
      ].each do |network|
        assert_equal true, networks.fetch(network)["internal"], "#{filename}: #{network} is externally routed"
      end
      refute networks.fetch("assistant-gateway-egress").fetch("internal", false),
        "#{filename}: the gateway's egress network has no route to the provider APIs"
      refute networks.fetch("assistant-codex-egress").fetch("internal", false),
        "#{filename}: Codex's egress network has no route to the provider API"

      # None of the three Go services may share a network with a datastore or
      # an execution surface — the gateway/validator/hunter-mcp are reachable
      # only from `web` (or, for the gateway, from hunter-mcp and the outside
      # world over its dedicated egress network).
      UNTRUSTED_SERVICES.each do |name|
        service_nets = service_networks(services.fetch(name))
        %w[db mongo runner ansible-executor].each do |forbidden_peer|
          shared = service_nets & service_networks(services.fetch(forbidden_peer))
          assert_empty shared, "#{filename}: #{name} shares #{shared.join(', ')} with #{forbidden_peer}"
        end
      end

      # The validator is additionally isolated from the gateway and hunter-mcp:
      # it is called only by `web`, never by another Assistant service.
      validator_networks = service_networks(services.fetch("assistant-validator"))
      %w[assistant-gateway hunter-mcp].each do |forbidden_peer|
        shared = validator_networks & service_networks(services.fetch(forbidden_peer))
        assert_empty shared,
          "#{filename}: assistant-validator shares #{shared.join(', ')} with #{forbidden_peer}"
      end
    end
  end

  def test_assistant_claude_has_a_persistent_home_volume
    each_compose do |filename, config|
      svc = config.fetch("services").fetch("assistant-claude")
      mounts = svc.fetch("volumes", []).map { |v| v.is_a?(String) ? v : v.to_a.join(":") }
      assert(mounts.any? { |m| m.include?("assistant_claude_home") && m.include?("/home/claude") },
        "#{filename}: assistant-claude must mount the assistant_claude_home volume at /home/claude")
    end
  end

  def test_assistant_codex_has_only_its_dedicated_persistent_home_volume
    each_compose do |filename, config|
      services = config.fetch("services")
      codex_mount = "assistant_codex_home:/home/codex/.codex"

      assert_equal [ codex_mount ], services.fetch("assistant-codex").fetch("volumes", []),
        "#{filename}: assistant-codex must persist only CODEX_HOME"
      assert config.fetch("volumes").key?("assistant_codex_home"),
        "#{filename}: assistant_codex_home is not declared"
      services.except("assistant-codex").each do |name, service|
        refute_includes service.fetch("volumes", []), codex_mount,
          "#{filename}: #{name} shares the Codex credential volume"
      end
    end
  end

  def test_assistant_codex_environment_is_chatgpt_only_and_exactly_bounded
    expected = {
      "ASSISTANT_CODEX_INGRESS_TOKEN" => "${HUNTER_ASSISTANT_CODEX_INGRESS_TOKEN:-}",
      "ASSISTANT_CODEX_ALLOWED_HOSTS" => "assistant-codex:8084",
      "ASSISTANT_CODEX_MCP_URL" => "http://hunter-mcp:8080/mcp",
      "ASSISTANT_CODEX_MCP_TOKEN" => "${HUNTER_ASSISTANT_GATEWAY_MCP_TOKEN}"
    }

    each_compose do |filename, config|
      services = config.fetch("services")
      service = services.fetch("assistant-codex")

      assert_equal expected, service.fetch("environment"),
        "#{filename}: assistant-codex environment widened beyond its ingress and MCP boundary"
      %w[OPENAI_API_KEY CODEX_API_KEY ASSISTANT_OPENAI_API_KEY].each do |name|
        refute service.fetch("environment").key?(name),
          "#{filename}: assistant-codex exposes provider API-key variable #{name}"
      end
      assert_equal "${HUNTER_ASSISTANT_CODEX_URL:-http://assistant-codex:8084}",
        services.fetch("web").fetch("environment").fetch("ASSISTANT_CODEX_URL")
      assert_equal "${HUNTER_ASSISTANT_CODEX_INGRESS_TOKEN:-}",
        services.fetch("web").fetch("environment").fetch("ASSISTANT_CODEX_INGRESS_TOKEN")
    end
  end

  def test_assistant_codex_hardening_and_resources_match_claude
    each_compose do |filename, config|
      services = config.fetch("services")
      claude = services.fetch("assistant-claude")
      codex = services.fetch("assistant-codex")
      comparable_keys = HARDENING_KEYS - [ "security_opt" ]

      assert_equal claude.slice(*comparable_keys), codex.slice(*comparable_keys),
        "#{filename}: assistant-codex hardening/resources differ from assistant-claude"
      assert_equal [ "no-new-privileges:true", "seccomp=./ops/assistant/seccomp/codex.json" ],
        codex.fetch("security_opt"), "#{filename}: assistant-codex seccomp boundary"
      assert_equal [ "CMD", "/hunter-assistant-codex", "-healthcheck" ],
        codex.fetch("healthcheck").fetch("test"), "#{filename}: assistant-codex healthcheck"
    end
  end

  # The retired gateway path must not start on a default `up`. Placing the two
  # services behind the `legacy-gateway` profile keeps them defined and hardened
  # (for anyone who deliberately opts back in) while removing them from the
  # default stack the Claude Code chat replaces.
  def test_legacy_gateway_and_validator_are_profile_gated
    each_compose do |filename, config|
      LEGACY_PROFILE_SERVICES.each do |name|
        profiles = config.fetch("services").fetch(name).fetch("profiles", [])
        assert_equal [ "legacy-gateway" ], profiles,
          "#{filename}: #{name} must sit behind the legacy-gateway profile so a default up does not start it"
      end
    end
  end

  # The three custom AppArmor profiles under ops/assistant/apparmor/ are kept in
  # the repository (for an operator who wants to load one manually) but are no
  # longer wired into Compose: apparmor_parser is never run automatically, so a
  # security_opt referencing an unloaded profile made `docker compose up` fail
  # outright (see docs/superpowers/specs/2026-07-26-hunter-assistant-zero-step-activation-delta.md).
  # Docker's built-in docker-default profile applies to these services instead.
  # This asserts the seccomp half of that hardening is untouched and that
  # apparmor= cannot silently reappear in either compose file without a
  # deliberate decision.
  def test_neither_compose_file_declares_a_custom_apparmor_profile
    each_compose do |filename, config|
      services = config.fetch("services")

      UNTRUSTED_SERVICES.each do |name|
        options = services.fetch(name).fetch("security_opt")
        assert options.any? { |option| option.start_with?("seccomp=") },
          "#{filename}: #{name} has no seccomp profile"
      end
    end

    COMPOSE_FILES.each do |filename|
      refute_match(/apparmor=/, ROOT.join(filename).read,
        "#{filename}: still declares a custom AppArmor profile")
    end
  end

  # No service declares a Compose file-backed secret any more: the machine
  # credentials are plain environment variables (see assistant_secret_paths_test.rb),
  # and the two provider keys were never Compose secrets either.
  def test_no_compose_service_declares_a_file_backed_secret
    each_compose do |filename, config|
      refute config.key?("secrets"), "#{filename}: still declares top-level Compose secrets"

      config.fetch("services").each do |service_name, service|
        assert_empty service_secrets(service), "#{filename}: #{service_name} still mounts a file-backed secret"
      end
    end
  end

  # Task 5 makes ASSISTANT_ENABLED a kill override, so no service may bake in a
  # default value for it (see assistant_secret_paths_test.rb for the full
  # rationale); this only re-checks it is absent from web's environment block,
  # which used to hold `${ASSISTANT_ENABLED:-false}`. Only `web` runs the Rails
  # code that reads it — the three Go services never reference it at all.
  def test_assistant_is_not_forced_off_by_default_in_either_compose_definition
    each_compose do |filename, config|
      refute config.fetch("services").fetch("web").fetch("environment", {}).key?("ASSISTANT_ENABLED"),
        "#{filename}: web bakes in a value for ASSISTANT_ENABLED"
    end
  end

  def test_service_specific_mandatory_access_profiles_default_deny_dangerous_operations
    profiles = {
      "gateway" => "hunter-assistant-gateway",
      "mcp" => "hunter-mcp",
      "validator" => "hunter-assistant-validator"
    }

    profiles.each do |service, apparmor_name|
      seccomp = JSON.parse(ROOT.join("ops/assistant/seccomp/#{service}.json").read)
      assert_equal "SCMP_ACT_ERRNO", seccomp.fetch("defaultAction")
      allowed = seccomp.fetch("syscalls")
        .select { |rule| rule.fetch("action") == "SCMP_ACT_ALLOW" }
        .flat_map { |rule| rule.fetch("names") }
      # fsopen/fsmount/fsconfig/fspick/move_mount/open_tree are the new mount API:
      # allowing any of them would hand back the mounting power `mount` is denied
      # for, so they are refused by name rather than left to be added by accident.
      %w[mount umount2 ptrace unshare keyctl bpf init_module finit_module kexec_load
         fsopen fsmount fsconfig fspick move_mount open_tree].each do |syscall|
        refute_includes allowed, syscall, "#{service} seccomp permits #{syscall}"
      end

      # runc >= 1.2 fstatfs()es the exec fifo's descriptor to prove it is not a
      # procfs magic link before reopening it, and does so after this profile is
      # applied. Without fstatfs every container using this profile dies in init
      # with "reopen exec fifo ... operation not permitted" and exits 255.
      assert_includes allowed, "fstatfs",
        "#{service} seccomp omits fstatfs; runc cannot start the container"

      # Go's net.Listen sets socket options (IPV6_V6ONLY, SO_REUSEADDR) via
      # setsockopt while opening the listener, before bind/listen. With
      # defaultErrnoRet=38 a denied setsockopt returns ENOSYS, net.Listen fails
      # ("setsockopt: function not implemented"), ListenAndServe returns, the
      # process exits and restart:unless-stopped crash-loops it — so the service
      # never becomes resolvable and every turn fails as gateway_dns_failure.
      # getsockopt alone is not enough; the listener path needs setsockopt too.
      assert_includes allowed, "setsockopt",
        "#{service} seccomp omits setsockopt; Go's net.Listen cannot open a socket and the container crash-loops"

      # ENOSYS rather than EPERM: a denied syscall must look unimplemented so the
      # runtime's own fallback paths engage instead of hard-failing. The syscall is
      # still never executed.
      assert_equal 38, seccomp.fetch("defaultErrnoRet"),
        "#{service} seccomp returns EPERM for denied syscalls; use ENOSYS (38)"
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

  # `docker compose up` is the whole enablement step, so it must never run stale
  # code. Compose's default pull_policy ("missing") builds an image only when one
  # is absent and reuses a stale image forever otherwise. That is how an old
  # gateway binary — still expecting the deleted /run/assistant/secrets mount —
  # kept crash-looping and made every turn fail as gateway_unreachable while the
  # source on disk was correct.
  def test_every_dev_service_that_builds_rebuilds_on_up
    config = YAML.safe_load_file(ROOT.join("docker-compose.yaml"), aliases: true)

    building = config.fetch("services").select { |_name, service| service.key?("build") }
    refute_empty building, "no dev service builds; this test is asserting nothing"

    building.each do |name, service|
      assert_equal "build", service["pull_policy"],
        "docker-compose.yaml: #{name} builds but does not set pull_policy: build, " \
        "so `docker compose up` will reuse a stale image"
    end
  end

  # Production pulls published, CI-built images by tag. Forcing a local build there
  # would bypass the registry the release gate scans and publishes.
  def test_production_pulls_images_instead_of_building_them
    config = YAML.safe_load_file(ROOT.join("docker-compose.prod.yaml"), aliases: true)

    config.fetch("services").each do |name, service|
      refute_equal "build", service["pull_policy"],
        "docker-compose.prod.yaml: #{name} would build locally instead of pulling"
    end
  end

  def test_ci_publishes_immutable_commit_tags_for_every_assistant_image
    workflow = ROOT.join(".gitea/workflows/build.yml").read
    %w[
      ASSISTANT_GATEWAY_IMAGE
      ASSISTANT_MCP_IMAGE
      ASSISTANT_VALIDATOR_IMAGE
    ].each do |image|
      assert_includes workflow, "${{ env.#{image} }}:${{ gitea.sha }}"
    end
  end

  # .env now holds every Assistant secret, so it is the file that must never reach
  # BuildKit; .env.example is the only member of that family safe to ship.
  # secrets/ no longer feeds any service, but an operator upgrading in place may
  # still have real keys sitting there, so the directory stays excluded outright —
  # with no carve-outs, since its documentation and examples were deleted.
  def test_local_credentials_are_excluded_from_every_root_image_build_context
    dockerignore = ROOT.join(".dockerignore").read.lines.map(&:strip)

    assert_includes dockerignore, ".env"
    assert_includes dockerignore, ".env.*"
    assert_includes dockerignore, "!.env.example"
    assert_includes dockerignore, "secrets/"
    %w[secrets/dev secrets/prod !secrets/README.md !secrets/examples/].each do |retired|
      refute_includes dockerignore, retired, "#{retired} no longer exists; the rule is dead"
    end
  end

  # Compares the parsed per-service hardening settings rather than counting raw
  # substrings, which would also match the words inside comments and would pass
  # just as happily with `read_only: false`.
  def test_hardening_directives_match_between_both_compose_files
    shapes = COMPOSE_FILES.map do |name|
      config = YAML.safe_load_file(ROOT.join(name), aliases: true)
      config.fetch("services").transform_values do |service|
        service.slice(*HARDENING_KEYS)
      end
    end

    assert_equal shapes.first.keys.sort, shapes.last.keys.sort,
      "the compose files define different services"
    shapes.first.each_key do |service_name|
      assert_equal shapes.first.fetch(service_name), shapes.last.fetch(service_name),
        "#{service_name} has diverged in runtime hardening between the compose files"
    end
  end

  # Would have caught round 1's "bootstrap scripts are not in the image": the
  # command referenced /app/ops/assistant/bootstrap.sh, which the Dockerfile
  # never copied. Resolves each referenced path through the actual COPY rules,
  # so a COPY retargeted to a different destination fails here even though the
  # source still exists in the context. Paths are scanned out of the whole
  # command rather than matched at token start, so one wrapped in `sh -c "..."`
  # is checked too.
  IN_IMAGE_PATH = %r{/app/[A-Za-z0-9._/-]*[A-Za-z0-9._-]}

  def test_every_path_a_compose_command_executes_exists_in_the_image
    ignored = ROOT.join(".dockerignore").read.lines.map(&:strip)
      .reject { |line| line.empty? || line.start_with?("#") }
    negated = ignored.select { |rule| rule.start_with?("!") }.map { |rule| rule.delete_prefix("!") }

    each_compose do |filename, config|
      config.fetch("services").each do |service_name, service|
        next unless service.key?("build") || service.fetch("image", "").include?("-web:")

        Array(service["command"]).grep(String).flat_map { |token| token.scan(IN_IMAGE_PATH) }.each do |path|
          source = build_context_source_for(path)

          assert source,
            "#{filename}: #{service_name} runs #{path}, which no Dockerfile COPY places in the image"

          relative = source.relative_path_from(ROOT).to_s
          dropped = ignored.reject { |rule| rule.start_with?("!") }.any? do |rule|
            relative.start_with?(rule.chomp("/")) && negated.none? { |keep| relative.start_with?(keep.chomp("/")) }
          end
          refute dropped, "#{filename}: #{service_name} runs #{path}, but .dockerignore excludes #{relative}"
        end
      end
    end
  end

  # Compose refuses to start a stack whose depends_on graph has a cycle.
  def test_the_service_dependency_graph_is_acyclic
    each_compose do |filename, config|
      services = config.fetch("services")
      edges = services.transform_values do |service|
        dependencies = service.fetch("depends_on", {})
        dependencies.is_a?(Hash) ? dependencies.keys : Array(dependencies)
      end

      visiting = {}
      settled = {}
      walk = lambda do |name, trail|
        return if settled[name]

        refute visiting[name], "#{filename}: dependency cycle #{(trail + [ name ]).join(' -> ')}"
        visiting[name] = true
        edges.fetch(name, []).each do |dependency|
          assert services.key?(dependency),
            "#{filename}: #{name} depends on undefined service #{dependency}"
          walk.call(dependency, trail + [ name ])
        end
        visiting[name] = false
        settled[name] = true
      end

      edges.each_key { |name| walk.call(name, []) }
    end
  end

  # The old design let one shell-only one-shot (assistant-secrets-init) sit in
  # web's dependency closure, justified because it needed no database and
  # could fail in only one narrow, stack-wide way. That one-shot — and the
  # RabbitMQ broker it unblocked — are deleted entirely now: web depends on
  # exactly db and mongo, and no Assistant service can gate Control Center's
  # boot at all any more.
  def test_no_assistant_service_can_gate_control_center
    each_compose do |filename, config|
      dependencies = config.fetch("services").fetch("web").fetch("depends_on").keys

      assert_equal %w[db mongo].sort, dependencies.sort,
        "#{filename}: web depends on #{dependencies.join(', ')}; only db and mongo should gate it"
    end
  end

  # Rails' ProviderCredentials calls a key with *internal* whitespace or control
  # characters "valid" while the gateway's readSecret rejects it, so the gateway
  # drops that provider and the chat still offers it — every turn then ends as
  # provider_not_allowed with the cause visible only in the gateway log. Closing
  # that needs a ninth reason code threaded through Rails, the client copy map
  # and Go, judged disproportionate; the accepted alternative is that an
  # operator hitting the symptom finds the cause wherever they happen to look.
  # Both sides moved from files to environment variables, but neither
  # classifier's algorithm changed, so the asymmetry — and this documentation —
  # still applies. secrets/README.md, which used to carry a third copy, was
  # deleted along with the rest of the file-based secret scaffolding.
  def test_the_malformed_key_limitation_is_documented_everywhere_an_operator_looks
    %w[
      docs/runbooks/hunter-assistant-incident-response.md
      docs/security/hunter-assistant-production-checklist.md
    ].each do |name|
      body = ROOT.join(name).read

      assert_includes body, "provider_not_allowed",
        "#{name} does not name the symptom of a malformed provider key"
      assert_includes body, "control characters",
        "#{name} does not name the cause of a malformed provider key"
    end
  end

  def test_neither_procfile_starts_a_second_assistant_event_consumer
    # The Assistant event consumer is deleted entirely (Assistant::EventIngestor
    # is now called synchronously from TurnJob/ValidationDispatcher), so a
    # Procfile entry for it would start a process pointed at a class that no
    # longer exists.
    %w[web/Procfile.dev web/Procfile.prod].each do |name|
      body = ROOT.join(name).read

      refute_match(/Assistant::EventConsumer/, body,
        "#{name} starts an Assistant event consumer that no longer exists")
    end
  end

  def test_git_ignores_secret_material_but_keeps_documentation
    ignored = ROOT.join(".gitignore").read

    assert_includes ignored, "/secrets/*"
    assert_includes ignored, "!/secrets/.keep"
  end

  private

  def each_compose
    COMPOSE_FILES.each do |filename|
      config = YAML.safe_load_file(ROOT.join(filename), aliases: true)
      yield filename, config
    end
  end

  # Each non-stage COPY in the root Dockerfile as [sources, destination,
  # destination_is_directory], with destinations resolved against WORKDIR /app.
  def dockerfile_copy_rules
    @dockerfile_copy_rules ||= ROOT.join("Dockerfile").read.lines.filter_map do |line|
      stripped = line.strip
      next unless stripped.start_with?("COPY ")
      next if stripped.include?("--from=")

      parts = stripped.delete_prefix("COPY ").split(/\s+/)
      raw_destination = parts.pop
      [ parts, File.expand_path(raw_destination, "/app"), raw_destination.end_with?("/", ".") ]
    end
  end

  # The build-context path that actually lands at in_image_path, or nil. Honours
  # the COPY *destination*, so retargeting a COPY elsewhere stops resolving here
  # even though the source file still exists in the context.
  def build_context_source_for(in_image_path)
    dockerfile_copy_rules.each do |sources, destination, destination_is_directory|
      sources.each do |source|
        context_path = ROOT.join(source.chomp("/"))

        if source.end_with?("/") || context_path.directory?
          prefix = "#{destination.chomp('/')}/"
          next unless in_image_path.start_with?(prefix)

          candidate = context_path.join(in_image_path.delete_prefix(prefix))
          return candidate if candidate.exist?
        else
          landed = destination_is_directory ? File.join(destination, File.basename(source)) : destination
          return context_path if landed == in_image_path && context_path.exist?
        end
      end
    end
    nil
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
