require "test_helper"

class NavigationPlaceholdersTest < ActionDispatch::IntegrationTest
  PATHS = %w[/bugs /stats /account /settings /notifications].freeze

  test "each placeholder renders for an authenticated user" do
    sign_in_as(User.take)
    PATHS.each do |path|
      get path
      assert_response :success, "expected 200 for #{path}"
    end
  end

  test "each placeholder redirects an unauthenticated visitor to sign in" do
    PATHS.each do |path|
      get path
      assert_redirected_to new_session_path, "expected redirect for #{path}"
    end
  end
end
