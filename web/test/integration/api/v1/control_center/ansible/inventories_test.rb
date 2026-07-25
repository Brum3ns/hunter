require "test_helper"
require "base64"

class Api::V1::ControlCenter::Ansible::InventoriesTest < ActionDispatch::IntegrationTest
  YAML = "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.0.0.10\n"

  setup { @user = users(:one) }

  test "requires authentication and the control center bearer scope" do
    get "/api/v1/control_center/ansible/inventories"
    assert_response :unauthorized

    _token, raw = ApiToken.generate(user: @user, name: "programs-only", scopes: [ "programs" ])
    get "/api/v1/control_center/ansible/inventories", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
  end

  test "session CRUD accepts a default credential but not protected host-key metadata" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "secret", created_by: @user
    )
    variable_set = ControlCenter::Ansible::VariableSet.create!(name: "Inventory", created_by: @user)
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/inventories", params: {
      name: "Workers", description: "VPN workers", yaml_content: YAML,
      default_credential_id: credential.id, variable_set_ids: [ variable_set.id ],
      known_hosts: "forged", host_key_fingerprints: { "worker" => "forged" }
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal %w[checksum created_at default_credential_id description host_key_fingerprints id known_hosts_configured name updated_at variable_set_ids yaml_content], body.keys.sort
    assert_equal credential.id, body["default_credential_id"]
    assert_equal [ variable_set.id ], body["variable_set_ids"]
    inventory = ControlCenter::Ansible::Inventory.find(body["id"])
    assert_nil inventory.known_hosts
    assert_equal({}, inventory.host_key_fingerprints)

    get "/api/v1/control_center/ansible/inventories"
    assert_response :success
    assert_equal body["id"], JSON.parse(response.body).fetch("inventories").sole["id"]

    patch "/api/v1/control_center/ansible/inventories/#{body["id"]}",
      params: { name: "Updated", default_credential_id: nil }, as: :json
    assert_response :success
    assert_nil JSON.parse(response.body)["default_credential_id"]

    delete "/api/v1/control_center/ansible/inventories/#{body["id"]}"
    assert_response :no_content
  end

  test "a scoped bearer can create an inventory" do
    _token, raw = ApiToken.generate(user: @user, name: "control-center", scopes: [ "control_center" ])

    post "/api/v1/control_center/ansible/inventories",
      params: { name: "Bearer", yaml_content: YAML },
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json

    assert_response :created
    assert_equal "Bearer", JSON.parse(response.body)["name"]
  end

  test "returns not found and validation envelopes" do
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/inventories/0"
    assert_response :not_found

    post "/api/v1/control_center/ansible/inventories",
      params: { name: "Unsafe", yaml_content: "---\nall:\n  vars:\n    ansible_password: secret\n" }, as: :json
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body).dig("details", "yaml_content"),
      "ansible_password is a reserved connection variable"
  end

  test "fast validation returns all errors without persistence" do
    sign_in_as(@user)

    assert_no_difference -> { ControlCenter::Ansible::Inventory.count } do
      post "/api/v1/control_center/ansible/inventories/validate",
        params: { yaml_content: "---\nall:\n  hosts: []\n" }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal false, body["valid"]
    assert_equal [ "all.hosts must be a mapping" ], body["errors"]
  end

  test "queues host scan syntax and connectivity tasks and exposes safe polling metadata" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: @user
    )
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: YAML, default_credential: credential,
      known_hosts: "worker ssh-ed25519 AAAA", host_key_fingerprints: { "worker:22" => "SHA256:ok" },
      created_by: @user
    )
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: "---\n- hosts: all\n  tasks: []\n", created_by: @user
    )
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/inventories/#{inventory.id}/host_key_scan", as: :json
    assert_response :accepted
    scan = JSON.parse(response.body)
    assert_equal "host_key_scan", scan["kind"]
    refute_match(/payload|password|private_key|fleet-secret/i, response.body)

    post "/api/v1/control_center/ansible/inventories/#{inventory.id}/syntax_check",
      params: { playbook_id: playbook.id }, as: :json
    assert_response :accepted
    assert_equal "syntax_check", JSON.parse(response.body)["kind"]

    post "/api/v1/control_center/ansible/inventories/#{inventory.id}/connectivity_test", as: :json
    assert_response :accepted
    assert_equal "connectivity_test", JSON.parse(response.body)["kind"]
    refute_includes response.body, "fleet-secret"

    get "/api/v1/control_center/ansible/inventories/#{inventory.id}/executor_tasks/#{scan.fetch('id')}"
    assert_response :success
    assert_equal "queued", JSON.parse(response.body)["status"]
    refute_match(/execution_payload|lease_digest|password|private_key/i, response.body)
  end

  test "host scan polling returns candidates as untrusted" do
    inventory = ControlCenter::Ansible::Inventory.create!(name: "Workers", yaml_content: YAML, created_by: @user)
    task = ControlCenter::Ansible::ExecutorTask.create!(
      kind: "host_key_scan", status: "succeeded", inventory:, created_by: @user,
      claim_deadline: 5.minutes.from_now,
      result: { "candidates" => [ {
        "host" => "worker", "port" => 22,
        "known_hosts_line" => "worker ssh-ed25519 AAAA",
        "fingerprint" => "SHA256:candidate", "trusted" => false
      } ] }
    )
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/inventories/#{inventory.id}/executor_tasks/#{task.id}"

    assert_response :success
    candidate = JSON.parse(response.body).dig("result", "candidates", 0)
    assert_equal false, candidate["trusted"]
  end

  test "confirms a host key only when the out-of-band fingerprint matches" do
    inventory = ControlCenter::Ansible::Inventory.create!(name: "Workers", yaml_content: YAML, created_by: @user)
    encoded = Base64.strict_encode64("test-host-public-key")
    digest = Base64.strict_encode64(Digest::SHA256.digest("test-host-public-key")).delete_suffix("=")
    fingerprint = "SHA256:#{digest}"
    candidate = {
      host: "worker", port: 22,
      known_hosts_line: "worker ssh-ed25519 #{encoded}",
      scanned_fingerprint: fingerprint
    }
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/inventories/#{inventory.id}/confirm_host_keys",
      params: { candidates: [ candidate.merge(expected_fingerprint: "SHA256:wrong") ] }, as: :json
    assert_response :unprocessable_entity
    assert_nil inventory.reload.known_hosts

    post "/api/v1/control_center/ansible/inventories/#{inventory.id}/confirm_host_keys",
      params: { candidates: [ candidate.merge(expected_fingerprint: fingerprint) ] }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal({ "worker:22" => fingerprint }, body["host_key_fingerprints"])
    assert_equal true, body["known_hosts_configured"]
  end
end
