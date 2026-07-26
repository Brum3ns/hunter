require "test_helper"

class Assistant::ServiceIdentityTest < ActiveSupport::TestCase
  test "generate persists only a digest and authenticates the expected role" do
    identity, raw = Assistant::ServiceIdentity.generate!(name: "MCP reader", role: "mcp_reader")

    refute_equal raw, identity.token_digest
    assert_equal Digest::SHA256.hexdigest(raw), identity.token_digest
    assert_equal identity, Assistant::ServiceIdentity.authenticate(raw, role: "mcp_reader")
    assert_nil Assistant::ServiceIdentity.authenticate(raw, role: "gateway")
    refute_includes identity.attributes.values, raw
  end

  test "disabled identities fail closed" do
    identity, raw = Assistant::ServiceIdentity.generate!(name: "MCP reader", role: "mcp_reader")
    identity.update!(enabled: false, rotated_at: Time.current)

    assert_nil Assistant::ServiceIdentity.authenticate(raw, role: "mcp_reader")
  end

  test "only the dedicated MCP reader role is accepted" do
    identity = Assistant::ServiceIdentity.new(name: "Gateway", role: "gateway", token_digest: "a" * 64)

    refute identity.valid?
    assert_includes identity.errors[:role], "is not included in the list"
  end
end
