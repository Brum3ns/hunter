require "test_helper"
require "rake"

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
