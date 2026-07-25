require "test_helper"

class Api::V1::ControlCenter::Ansible::VariableSetsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires authentication and the control center bearer scope" do
    get "/api/v1/control_center/ansible/variable_sets"
    assert_response :unauthorized

    _token, raw = ApiToken.generate(user: @user, name: "cves-only", scopes: [ "cves" ])
    get "/api/v1/control_center/ansible/variable_sets", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
  end

  test "session CRUD keeps secret values write-only while returning non-secret typed values" do
    sign_in_as(@user)
    post "/api/v1/control_center/ansible/variable_sets",
      params: { name: "Production", description: "Deploy settings" }, as: :json

    assert_response :created
    set = JSON.parse(response.body)
    assert_equal [], set["variables"]

    post "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables",
      params: { name: "api_token", value_type: "string", secret: true, value: "top-secret", position: 0 },
      as: :json
    assert_response :created
    secret = JSON.parse(response.body)
    assert_equal %w[configured id name position secret value value_type], secret.keys.sort
    assert_equal true, secret["configured"]
    assert_nil secret["value"]
    refute_includes response.body, "top-secret"

    post "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables",
      params: { name: "ports", value_type: "list", secret: false, value: "- 22\n- 443\n", position: 1 },
      as: :json
    assert_response :created
    assert_equal [ 22, 443 ], JSON.parse(response.body)["value"]

    post "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables",
      params: { name: "labels", value_type: "dictionary", secret: false,
                value: { "tier" => "worker" }, position: 2 }, as: :json
    assert_response :created
    assert_equal({ "tier" => "worker" }, JSON.parse(response.body)["value"])

    get "/api/v1/control_center/ansible/variable_sets/#{set["id"]}"
    assert_response :success
    refute_includes response.body, "top-secret"
    assert_equal %w[api_token ports labels], JSON.parse(response.body).fetch("variables").map { |item| item["name"] }

    patch "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables/#{secret["id"]}",
      params: { value: "", position: 2 }, as: :json
    assert_response :success
    assert_equal "top-secret", ControlCenter::Ansible::Variable.find(secret["id"]).typed_value

    patch "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables/#{secret["id"]}",
      params: { clear_value: true }, as: :json
    assert_response :unprocessable_entity
    assert_equal "top-secret", ControlCenter::Ansible::Variable.find(secret["id"]).typed_value

    patch "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables/#{secret["id"]}",
      params: { secret: false }, as: :json
    assert_response :unprocessable_entity
    persisted_secret = ControlCenter::Ansible::Variable.find(secret["id"])
    assert persisted_secret.secret?
    assert_equal "top-secret", persisted_secret.typed_value
    refute_includes response.body, "top-secret"

    patch "/api/v1/control_center/ansible/variable_sets/#{set["id"]}",
      params: { name: "Updated" }, as: :json
    assert_response :success
    assert_equal "Updated", JSON.parse(response.body)["name"]

    delete "/api/v1/control_center/ansible/variable_sets/#{set["id"]}/variables/#{secret["id"]}"
    assert_response :no_content
    delete "/api/v1/control_center/ansible/variable_sets/#{set["id"]}"
    assert_response :no_content
  end

  test "a scoped bearer can create a variable set and variable" do
    _token, raw = ApiToken.generate(user: @user, name: "control-center", scopes: [ "control_center" ])
    headers = { "Authorization" => "Bearer #{raw}" }

    post "/api/v1/control_center/ansible/variable_sets",
      params: { name: "Bearer" }, headers: headers, as: :json
    assert_response :created
    id = JSON.parse(response.body)["id"]

    post "/api/v1/control_center/ansible/variable_sets/#{id}/variables",
      params: { name: "enabled", value_type: "boolean", value: true, secret: false },
      headers: headers, as: :json
    assert_response :created
    assert_equal true, JSON.parse(response.body)["value"]
  end

  test "returns not found and typed validation envelopes" do
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/variable_sets/0"
    assert_response :not_found

    set = ControlCenter::Ansible::VariableSet.create!(name: "Production", created_by: @user)
    post "/api/v1/control_center/ansible/variable_sets/#{set.id}/variables",
      params: { name: "enabled", value_type: "boolean", value: "true", secret: false }, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert_includes body.dig("details", "serialized_value"), "must be a boolean"

    post "/api/v1/control_center/ansible/variable_sets/#{set.id}/variables",
      params: { name: "ansible_become_password", value_type: "string", value: "secret", secret: true }, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).dig("details", "name"),
      "is reserved for connection credentials"
  end
end
