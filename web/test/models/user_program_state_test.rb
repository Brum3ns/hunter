require "test_helper"

class UserProgramStateTest < ActiveSupport::TestCase
  setup { @user = User.create!(username: "hunter", password: "password123") }

  test "favorite_sids returns a set of sids" do
    @user.favorites.create!(program_sid: "abc")
    assert_equal Set["abc"], @user.favorite_sids
  end

  test "recent_views skips programs missing from mongo" do
    @user.program_views.create!(program_sid: "gone", viewed_at: Time.current)
    stub_methods(Programs::Source, find: ->(_sid) { nil }) do
      assert_empty @user.recent_views
    end
  end
end
