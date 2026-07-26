require "test_helper"
require "rake"
require "tmpdir"

class AssistantServiceTokensTest < ActiveSupport::TestCase
  setup do
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.load_rakefile(Rails.root.join("lib/tasks/assistant_service_tokens.rake").to_s)
    Rake::Task.define_task(:environment)
  end

  test "create prints a raw MCP reader token exactly once" do
    ENV["NAME"] = "hunter-mcp"
    ENV["ROLE"] = "mcp_reader"

    output, = capture_io { invoke_create }
    identity = Assistant::ServiceIdentity.find_by!(name: "hunter-mcp", enabled: true)
    raw = output.lines.last.strip

    assert_equal identity, Assistant::ServiceIdentity.authenticate(raw, role: "mcp_reader")
    assert_equal 1, output.scan(raw).length
  ensure
    clear_environment
  end

  test "create rejects unsupported roles" do
    ENV["NAME"] = "gateway"
    ENV["ROLE"] = "gateway"

    assert_raises(SystemExit) { capture_io { invoke_create } }
    assert_not Assistant::ServiceIdentity.exists?(name: "gateway")
  ensure
    clear_environment
  end

  test "duplicate names require explicit rotation" do
    Assistant::ServiceIdentity.generate!(name: "hunter-mcp", role: "mcp_reader")
    ENV["NAME"] = "hunter-mcp"
    ENV["ROLE"] = "mcp_reader"

    assert_raises(SystemExit) { capture_io { invoke_create } }

    ENV["ROTATE"] = "true"
    capture_io { invoke_create }
    records = Assistant::ServiceIdentity.where(name: "hunter-mcp").order(:id)
    assert_equal [ false, true ], records.pluck(:enabled)
    assert_not_nil records.first.rotated_at
  ensure
    clear_environment
  end

  test "bootstrap writes the mcp token to file without printing it" do
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join("assistant_mcp_hunter_token")
      output = capture_io do
        Assistant::BootstrapServiceToken.call(path: path)
      end.join

      assert_path_exists path
      assert_equal "400", (path.stat.mode & 0o777).to_s(8)
      refute_includes output, path.read.strip, "the raw token was printed"
      assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
    end
  end

  test "bootstrap service token is idempotent" do
    Dir.mktmpdir do |dir|
      path = Pathname.new(dir).join("assistant_mcp_hunter_token")
      Assistant::BootstrapServiceToken.call(path: path)
      first = path.read

      Assistant::BootstrapServiceToken.call(path: path)

      assert_equal first, path.read, "an existing token file was rewritten"
      assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
    end
  end

  test "bootstrap rotates an existing enabled mcp reader identity off" do
    Dir.mktmpdir do |dir|
      seeded, = Assistant::ServiceIdentity.generate!(name: "hunter-mcp", role: "mcp_reader")
      assert seeded.enabled?
      assert_nil seeded.rotated_at

      Assistant::BootstrapServiceToken.call(path: Pathname.new(dir).join("assistant_mcp_hunter_token"))

      seeded.reload
      assert_not seeded.enabled?, "the seeded identity was not rotated off"
      assert_not_nil seeded.rotated_at, "the seeded identity has no rotation timestamp"
      assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
    end
  end

  private

  def invoke_create
    @rake["assistant:service_tokens:create"].reenable
    @rake["assistant:service_tokens:create"].invoke
  end

  def clear_environment
    ENV.delete("NAME")
    ENV.delete("ROLE")
    ENV.delete("ROTATE")
  end
end
