require "test_helper"

class Api::V1::ControlCenter::Ansible::CredentialsTest < ActionDispatch::IntegrationTest
  METADATA_KEYS = %w[
    id name auth_type username public_key_fingerprint
    private_key_configured ssh_password_configured
    private_key_passphrase_configured become_password_configured
    last_used_at created_at updated_at
  ].sort.freeze

  setup { @user = users(:one) }

  test "requires authentication" do
    get "/api/v1/control_center/ansible/credentials"

    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "creates and serializes only credential metadata" do
    sign_in_as(@user)
    post "/api/v1/control_center/ansible/credentials", params: {
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "api-secret", become_password: "sudo-secret"
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal METADATA_KEYS, body.keys.sort
    assert_equal true, body["ssh_password_configured"]
    assert_equal true, body["become_password_configured"]
    refute_includes response.body, "api-secret"
    refute_includes response.body, "sudo-secret"
  end

  test "lists, shows, and destroys credential metadata" do
    credential = password_credential
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/credentials"
    assert_response :success
    item = JSON.parse(response.body).fetch("credentials").sole
    assert_equal METADATA_KEYS, item.keys.sort
    assert_equal credential.id, item["id"]

    get "/api/v1/control_center/ansible/credentials/#{credential.id}"
    assert_response :success
    assert_equal "workers", JSON.parse(response.body)["name"]
    refute_includes response.body, "old"

    delete "/api/v1/control_center/ansible/credentials/#{credential.id}"
    assert_response :no_content
    refute ControlCenter::Ansible::Credential.exists?(credential.id)
  end

  test "returns not found for an unknown credential" do
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/credentials/0"

    assert_response :not_found
    assert_equal "not_found", JSON.parse(response.body)["error"]
  end

  test "blank update retains the secret" do
    credential = password_credential
    sign_in_as(@user)

    patch "/api/v1/control_center/ansible/credentials/#{credential.id}",
      params: { username: "ops", ssh_password: "" }, as: :json

    assert_response :success
    assert_equal "old", credential.reload.ssh_password
    assert_equal "ops", credential.username
  end

  test "invalid explicit clear returns a validation envelope and retains the secret" do
    credential = password_credential
    sign_in_as(@user)

    patch "/api/v1/control_center/ansible/credentials/#{credential.id}",
      params: { clear_ssh_password: true }, as: :json

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert_includes body["detail"], "Ssh password must be configured"
    assert_equal "old", credential.reload.ssh_password
  end

  test "control-center-scoped bearer may list credentials without secrets" do
    password_credential
    _token, raw = ApiToken.generate(user: @user, name: "cc", scopes: [ "control_center" ])

    get "/api/v1/control_center/ansible/credentials",
      headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :success
    refute_includes response.body, "old"
  end

  test "wrong bearer scope is forbidden" do
    _token, raw = ApiToken.generate(user: @user, name: "cves", scopes: [ "cves" ])

    get "/api/v1/control_center/ansible/credentials",
      headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  private

  def password_credential
    ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "old", created_by: @user
    )
  end
end
