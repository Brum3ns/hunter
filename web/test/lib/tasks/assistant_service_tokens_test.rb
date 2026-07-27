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

  test "install_from_environment! stores only the digest of the supplied token" do
    raw = "mcp-token-#{SecureRandom.hex(16)}"

    identity = Assistant::ServiceIdentity.install_from_environment!(raw)

    assert identity.enabled?
    assert_equal "hunter-mcp", identity.name
    assert_equal "mcp_reader", identity.role
    assert_equal Assistant::ServiceIdentity.digest(raw), identity.token_digest
    refute_equal raw, identity.token_digest, "the raw token was persisted"
  end

  test "install_from_environment! is idempotent for an unchanged token" do
    raw = "mcp-token-#{SecureRandom.hex(16)}"
    first = Assistant::ServiceIdentity.install_from_environment!(raw)

    assert_no_difference -> { Assistant::ServiceIdentity.count } do
      assert_equal first.id, Assistant::ServiceIdentity.install_from_environment!(raw).id
    end
  end

  test "install_from_environment! rotates an existing enabled mcp reader off" do
    seeded, = Assistant::ServiceIdentity.generate!(name: "hunter-mcp", role: "mcp_reader")

    Assistant::ServiceIdentity.install_from_environment!("mcp-token-#{SecureRandom.hex(16)}")

    seeded.reload
    assert_not seeded.enabled?, "the seeded identity was not rotated off"
    assert_not_nil seeded.rotated_at, "the seeded identity has no rotation timestamp"
    assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
  end

  # token_digest carries an UNQUALIFIED unique index, so reverting to a token this
  # database has already seen must reactivate that row. A blind create! would raise
  # RecordNotUnique and take db:seed -- and therefore boot -- down with it.
  test "install_from_environment! can roll back to a previously used token" do
    first_raw = "mcp-token-#{SecureRandom.hex(16)}"
    original = Assistant::ServiceIdentity.install_from_environment!(first_raw)
    Assistant::ServiceIdentity.install_from_environment!("mcp-token-#{SecureRandom.hex(16)}")

    restored = Assistant::ServiceIdentity.install_from_environment!(first_raw)

    assert_equal original.id, restored.id
    assert restored.enabled?
    assert_nil restored.rotated_at
    assert_equal 1, Assistant::ServiceIdentity.where(enabled: true, role: "mcp_reader").count
  end

  test "install_from_environment! refuses a token too short to trust" do
    assert_raises(ArgumentError) do
      Assistant::ServiceIdentity.install_from_environment!("short")
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
