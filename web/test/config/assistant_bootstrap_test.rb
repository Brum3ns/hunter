require "fileutils"
require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

class AssistantBootstrapTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  SCRIPT = ROOT.join("ops/assistant/bootstrap.sh").freeze
  TOKEN_SCRIPT = ROOT.join("ops/assistant/bootstrap_service_token.rb").freeze
  GENERATED = %w[
    assistant_rabbitmq_provision_password
    assistant_rails_amqp_password
    assistant_gateway_amqp_password
    assistant_validator_amqp_password
    assistant_gateway_mcp_token
  ].freeze

  def test_generates_every_machine_credential_at_mode_0400
    Dir.mktmpdir do |dir|
      stdout, stderr, status = run_bootstrap(dir)

      assert status.success?, "bootstrap failed: #{stderr}"
      GENERATED.each do |name|
        path = Pathname.new(dir).join(name)
        assert_path_exists path, "#{name} was not generated"
        assert_equal "400", (path.stat.mode & 0o777).to_s(8), "#{name} has the wrong mode"
        refute_empty path.read.strip, "#{name} is empty"
      end
      assert_empty stdout.strip, "bootstrap printed to stdout"
    end
  end

  def test_never_prints_a_generated_value
    Dir.mktmpdir do |dir|
      first_stdout, first_stderr, _first_status = run_bootstrap(dir)
      values = GENERATED.map { |name| Pathname.new(dir).join(name).read.strip }
      stdout, stderr, _status = run_bootstrap(dir)

      values.each do |value|
        refute_includes first_stdout, value, "a secret value reached stdout on the first run"
        refute_includes first_stderr, value, "a secret value reached stderr on the first run"
        refute_includes stdout, value, "a secret value reached stdout"
        refute_includes stderr, value, "a secret value reached stderr"
      end
    end
  end

  def test_is_idempotent_and_never_rewrites_an_existing_secret
    Dir.mktmpdir do |dir|
      run_bootstrap(dir)
      before = GENERATED.to_h { |name| [ name, Pathname.new(dir).join(name).read ] }

      _stdout, stderr, status = run_bootstrap(dir)

      assert status.success?, "second run failed: #{stderr}"
      before.each do |name, value|
        assert_equal value, Pathname.new(dir).join(name).read, "#{name} was rewritten"
      end
    end
  end

  # The token bootstrap runs from two layouts: the repo checkout, where the Rails
  # root is a sibling web/ directory, and the container image, where ops/assistant
  # sits inside the Rails root at /app. A require_relative hardcoded to one of them
  # raises LoadError in the other, which no compose-parsing test can see.
  def test_the_token_bootstrap_resolves_the_rails_environment_in_both_layouts
    {
      "repo checkout" => "web/config",
      "container image" => "config"
    }.each do |layout, environment_directory|
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        scripts = root.join("ops/assistant")
        scripts.mkpath
        FileUtils.cp(TOKEN_SCRIPT, scripts.join(TOKEN_SCRIPT.basename))

        environment = root.join(environment_directory)
        environment.mkpath
        environment.join("environment.rb").write(<<~RUBY)
          module Assistant
            module BootstrapServiceToken
              def self.call(path:) = File.write(path, "resolved")
            end
          end
        RUBY

        target = root.join("token")
        _stdout, stderr, status = Open3.capture3(
          { "ASSISTANT_MCP_TOKEN_PATH" => target.to_s },
          "ruby", scripts.join(TOKEN_SCRIPT.basename).to_s
        )

        assert status.success?, "#{layout}: token bootstrap failed: #{stderr}"
        assert_equal "resolved", target.read, "#{layout}: the bootstrap did not run"
      end
    end
  end

  # Docker seeds a fresh named volume from the image directory at the mount
  # point. If /run/assistant/secrets is absent from the image it is created
  # root:root, and assistant-secrets-init runs as 1000:1000 and cannot write it.
  def test_the_image_pre_creates_the_secret_volume_directory_owned_by_the_runtime_user
    dockerfile = ROOT.join("Dockerfile").read

    assert_match(%r{mkdir -p /run/assistant/secrets}, dockerfile,
      "the image does not create the secret volume directory")
    assert_match(/chown -R 1000:1000 \/run\/assistant/, dockerfile,
      "the secret volume directory is not owned by the runtime user")
    assert_match(%r{chmod 0700 /run/assistant/secrets}, dockerfile,
      "the secret volume directory is not mode 0700")
  end

  # The one-shots execute these from /app; the image must actually contain them.
  def test_the_image_copies_the_bootstrap_scripts_and_their_openssl_dependency
    dockerfile = ROOT.join("Dockerfile").read

    assert_includes dockerfile, "COPY ops/assistant/ /app/ops/assistant/",
      "the image does not copy the bootstrap scripts"
    assert_match(/^\s*openssl/, dockerfile,
      "bootstrap.sh shells out to `openssl rand` but the image never installs it")
  end

  private

  def run_bootstrap(dir)
    Open3.capture3({ "ASSISTANT_SECRET_TARGET" => dir }, "sh", SCRIPT.to_s)
  end
end
