require "test_helper"

class Assistant::AdminPolicyTest < ActiveSupport::TestCase
  test "only the normalized configured administrator is allowed" do
    stub_methods(Assistant::AdminPolicy, configured_username: -> { "admin" }) do
      assert Assistant::AdminPolicy.allowed?(User.new(username: " ADMIN "))
      refute Assistant::AdminPolicy.allowed?(User.new(username: "operator"))
      refute Assistant::AdminPolicy.allowed?(nil)
    end
  end

  test "a blank configured username denies every user" do
    stub_methods(Assistant::AdminPolicy, configured_username: -> { "" }) do
      refute Assistant::AdminPolicy.allowed?(User.new(username: "admin"))
    end
  end
end
