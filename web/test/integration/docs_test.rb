require "test_helper"

class DocsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires a session" do
    get "/docs"
    assert_redirected_to new_session_path
  end

  test "renders the Swagger UI mount node and vendored assets" do
    sign_in_as(@user)
    get "/docs"
    assert_response :success
    assert_select "#swagger-ui", count: 1
    assert_select "link[href*=?]", "swagger-ui"
    assert_select "link[href*=?]", "swagger_ui_skin"
    assert_select "script[src*=?]", "swagger-ui-bundle"
  end

  test "the sidebar shows the API Docs link" do
    sign_in_as(@user)
    get root_path
    assert_select "a[href=?]", docs_path
  end

  test "the docs entry lights up as active on /docs" do
    sign_in_as(@user)
    get "/docs"
    assert_select "a[href=?][aria-current=page]", docs_path
  end
end
