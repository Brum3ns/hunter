require "test_helper"

class Api::V1::OpenapiTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "401 without a cookie or token" do
    get "/api/v1/openapi.json"
    assert_response :unauthorized
    assert_equal "unauthorized", JSON.parse(response.body)["error"]
  end

  test "session request gets the full document with every module tag" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"
    assert_response :success
    doc = JSON.parse(response.body)
    assert_equal "3.1.0", doc["openapi"]
    assert doc["paths"].key?("/api/v1/cves"), "cves documented"
    assert doc["paths"].key?("/api/v1/vulnerabilities"), "vulnerabilities documented"
    assert doc["paths"].key?("/api/v1/programs/changes"), "programs documented"
  end

  test "cves-scoped bearer gets only CVE paths" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/openapi.json", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :success
    doc = JSON.parse(response.body)
    assert doc["paths"].key?("/api/v1/cves")
    refute doc["paths"].key?("/api/v1/vulnerabilities")
    refute doc["paths"].key?("/api/v1/programs/changes")
  end

  test "the .json-less canonical path also resolves" do
    sign_in_as(@user)
    get "/api/v1/openapi"
    assert_response :success
    assert_equal "3.1.0", JSON.parse(response.body)["openapi"]
  end

  test "documents write-only Ansible credential inputs and metadata-only responses" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"

    assert_response :success
    doc = JSON.parse(response.body)
    collection = doc["paths"].fetch("/api/v1/control_center/ansible/credentials")
    assert_equal "control_center", collection.dig("get", "x-api-scope")
    assert_equal "control_center", collection.dig("post", "x-api-scope")

    input = doc.dig("components", "schemas", "CcAnsibleCredentialInput", "properties")
    %w[private_key ssh_password private_key_passphrase become_password].each do |secret|
      assert_equal true, input.dig(secret, "writeOnly")
    end

    output = doc.dig("components", "schemas", "CcAnsibleCredential", "properties")
    assert_nil output["private_key"]
    assert_nil output["ssh_password"]
    assert_nil output["private_key_passphrase"]
    assert_nil output["become_password"]
  end

  test "control-center bearer receives the Ansible credential contract" do
    _record, raw = ApiToken.generate(user: @user, name: "control-center", scopes: [ "control_center" ])

    get "/api/v1/openapi.json", headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :success
    doc = JSON.parse(response.body)
    assert doc["paths"].key?("/api/v1/control_center/ansible/credentials")
    refute doc["paths"].key?("/api/v1/cves")
  end

  test "documents the scoped Ansible authoring API without credential secret aliases" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"

    assert_response :success
    doc = JSON.parse(response.body)
    paths = %w[
      /api/v1/control_center/ansible/playbooks
      /api/v1/control_center/ansible/playbooks/{id}
      /api/v1/control_center/ansible/playbooks/validate
      /api/v1/control_center/ansible/playbooks/export
      /api/v1/control_center/ansible/inventories
      /api/v1/control_center/ansible/inventories/{id}
      /api/v1/control_center/ansible/inventories/validate
      /api/v1/control_center/ansible/variable_sets
      /api/v1/control_center/ansible/variable_sets/{id}
      /api/v1/control_center/ansible/variable_sets/{variable_set_id}/variables
      /api/v1/control_center/ansible/variable_sets/{variable_set_id}/variables/{id}
    ]
    paths.each do |path|
      operations = doc["paths"].fetch(path).except("parameters")
      assert operations.values.all? { |operation| operation["x-api-scope"] == "control_center" }, path
    end

    schemas = doc.dig("components", "schemas")
    %w[AnsiblePlaybook AnsibleInventory AnsibleVariableSet AnsibleVariable AnsibleValidationResult ValidationError].each do |name|
      assert schemas.key?(name), "#{name} schema is documented"
    end
    assert_equal true, schemas.dig("AnsibleVariable", "properties", "value", "readOnly")
    assert_includes schemas.dig("AnsibleVariable", "properties", "value", "type"), "null"

    authoring = schemas.slice("AnsiblePlaybook", "AnsibleInventory", "AnsibleVariableSet", "AnsibleVariable").to_json
    %w[private_key ssh_password private_key_passphrase become_password].each do |secret_alias|
      refute_includes authoring, secret_alias
    end
  end

  test "documents Ansible launch history events cancellation and executor health" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"

    assert_response :success
    paths = JSON.parse(response.body).fetch("paths")
    %w[
      /api/v1/control_center/ansible/run_groups
      /api/v1/control_center/ansible/run_groups/{id}
      /api/v1/control_center/ansible/run_groups/{id}/cancel
      /api/v1/control_center/ansible/runs/{id}
      /api/v1/control_center/ansible/runs/{id}/cancel
      /api/v1/control_center/ansible/runs/{run_id}/events
      /api/v1/control_center/ansible/executor_health
    ].each do |path|
      operations = paths.fetch(path).except("parameters")
      assert operations.values.all? { |operation| operation["x-api-scope"] == "control_center" }, path
    end
  end

  test "documents isolated Ansible inventory utility operations" do
    sign_in_as(@user)
    get "/api/v1/openapi.json"

    assert_response :success
    paths = JSON.parse(response.body).fetch("paths")
    %w[
      /api/v1/control_center/ansible/inventories/{id}/syntax_check
      /api/v1/control_center/ansible/inventories/{id}/host_key_scan
      /api/v1/control_center/ansible/inventories/{id}/confirm_host_keys
      /api/v1/control_center/ansible/inventories/{id}/connectivity_test
      /api/v1/control_center/ansible/inventories/{id}/executor_tasks/{task_id}
    ].each do |path|
      operations = paths.fetch(path).except("parameters")
      assert operations.values.all? { |operation| operation["x-api-scope"] == "control_center" }, path
    end
  end
end
