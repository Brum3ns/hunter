require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "downcases and strips username" do
    user = User.new(username: " ADMIN ")
    assert_equal("admin", user.username)
  end
end
