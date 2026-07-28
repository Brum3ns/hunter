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

    post "/api/v1/control_center/templates",
      params: valid_body.merge(created_by: "forged"), as: :json
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal %w[commands created_at created_by description id kind name output tags target updated_at yaml],
      body.keys.sort
    assert_equal @user.username, body["created_by"]
    id = body["id"]

    get "/api/v1/control_center/templates"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["templates"].length

    get "/api/v1/control_center/templates/#{id}"
    assert_response :success
    assert_equal "probe", JSON.parse(response.body)["name"]

    patch "/api/v1/control_center/templates/#{id}", params: { description: "updated" }, as: :json
    assert_response :success
    assert_equal "updated", JSON.parse(response.body)["description"]

    patch "/api/v1/control_center/templates/#{id}",
      params: { commands: [{ command: "httpx", args: ["a\nb"], operator: "" }] }, as: :json
    assert_response :unprocessable_entity
    error = JSON.parse(response.body)
    assert_equal %w[detail error], error.keys.sort
    assert_equal "unprocessable_entity", error["error"]
    assert_equal "updated", ControlCenter::Template.find(id).description

    delete "/api/v1/control_center/templates/#{id}"
    assert_response :no_content
  end

  test "rejects a template with an invalid command" do
    sign_in_as(@user)
    body = valid_body.merge(commands: [{ command: "httpx", args: ["a\nb"], operator: "" }])
    post "/api/v1/control_center/templates", params: body, as: :json
    assert_response :unprocessable_entity
    error = JSON.parse(response.body)
    assert_equal %w[detail error], error.keys.sort
    assert_equal "unprocessable_entity", error["error"]
    assert error["detail"].any?
  end

  test "a control center bearer can create and update a template" do
    _token, raw = ApiToken.generate(user: @user, name: "control-center", scopes: [ "control_center" ])
    headers = { "Authorization" => "Bearer #{raw}" }

    post "/api/v1/control_center/templates", params: valid_body,
      headers: headers, as: :json
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal @user.username, body["created_by"]

    patch "/api/v1/control_center/templates/#{body.fetch("id")}",
      params: { description: "via token" }, headers: headers, as: :json
    assert_response :success
    assert_equal "via token", JSON.parse(response.body)["description"]
  end

  test "a bearer without the control center scope cannot access templates" do
    _token, raw = ApiToken.generate(user: @user, name: "cves-only", scopes: [ "cves" ])

    get "/api/v1/control_center/templates",
      headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body).fetch("error")
  end

  test "validate endpoint reports errors without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate",
         params: { commands: [{ command: "", args: [], operator: "" }] }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["valid"]
    assert_equal 0, ControlCenter::Template.count
  end

  test "validate returns rendered yaml for structured params without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate",
         params: { name: "probe", kind: "cmdscript",
                   commands: [{ command: "httpx", args: ["-u", "x", "-silent"], operator: "" }] },
         as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["valid"]
    assert_includes body["yaml"], "command: httpx"
    assert_includes body["yaml"], "['-u', 'x']"
    assert_equal 0, ControlCenter::Template.count
  end
end
