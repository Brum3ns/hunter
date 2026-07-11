require "test_helper"

class Api::V1::ControlCenter::TemplatesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def valid_body
    { name: "probe", kind: "cmdscript", description: "d",
      commands: [{ command: "httpx", args: ["-silent"], operator: "" }] }
  end

  test "requires auth" do
    get "/api/v1/control_center/templates"
    assert_response :unauthorized
  end

  test "creates, lists, shows, updates, and destroys a template" do
    sign_in_as(@user)

    post "/api/v1/control_center/templates", params: valid_body, as: :json
    assert_response :created
    id = JSON.parse(response.body)["id"]

    get "/api/v1/control_center/templates"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["templates"].length

    get "/api/v1/control_center/templates/#{id}"
    assert_response :success
    assert_equal "probe", JSON.parse(response.body)["name"]

    patch "/api/v1/control_center/templates/#{id}", params: { description: "updated" }, as: :json
    assert_response :success
    assert_equal "updated", JSON.parse(response.body)["description"]

    delete "/api/v1/control_center/templates/#{id}"
    assert_response :no_content
  end

  test "rejects a template with a non-allowlisted command" do
    sign_in_as(@user)
    body = valid_body.merge(commands: [{ command: "rm", args: ["-rf", "/"], operator: "" }])
    post "/api/v1/control_center/templates", params: body, as: :json
    assert_response :unprocessable_entity
  end

  test "validate endpoint reports errors without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate",
         params: { commands: [{ command: "rm", args: [], operator: "" }] }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["valid"]
    assert_equal 0, ControlCenter::Template.count
  end
end
