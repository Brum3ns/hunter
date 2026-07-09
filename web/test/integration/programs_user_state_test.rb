require "test_helper"

class ProgramsUserStateTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one); sign_in_as(@user) }

  test "favorite create then destroy" do
    post "/programs/abc/favorite", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal true, JSON.parse(response.body)["favorited"]
    assert_equal 1, @user.favorites.count

    delete "/programs/abc/favorite", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal 0, @user.favorites.reload.count
  end

  test "view tracks a program_view" do
    post "/programs/abc/view", headers: { "X-Requested-With" => "XMLHttpRequest" }
    assert_response :success
    assert_equal 1, @user.program_views.count
  end
end
