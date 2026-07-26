require "minitest/autorun"
require "open3"
require "pathname"
require "tmpdir"

class AssistantBootstrapTest < Minitest::Test
  ROOT = Pathname.new(__dir__).join("../../..").expand_path.freeze
  SCRIPT = ROOT.join("ops/assistant/bootstrap.sh").freeze
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

  private

  def run_bootstrap(dir)
    Open3.capture3({ "ASSISTANT_SECRET_TARGET" => dir }, "sh", SCRIPT.to_s)
  end
end
