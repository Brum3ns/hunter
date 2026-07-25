require "test_helper"

class Api::V1::ControlCenter::Ansible::RunGroupsTest < ActionDispatch::IntegrationTest
  PLAYBOOK_YAML = "---\n- hosts: workers\n  tasks: []\n"
  INVENTORY_YAML = "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.10.0.8\n"

  setup do
    @user = users(:one)
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "Deploy", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: @user
    )
    @inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers", yaml_content: INVENTORY_YAML, default_credential: @credential,
      known_hosts: "worker ssh-ed25519 AAAA", host_key_fingerprints: { "worker" => "SHA256:ok" },
      created_by: @user
    )
    @playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: PLAYBOOK_YAML, created_by: @user
    )
  end

  test "requires authentication and control center bearer scope" do
    get "/api/v1/control_center/ansible/run_groups"
    assert_response :unauthorized

    _token, raw = ApiToken.generate(user: @user, name: "cves-only", scopes: [ "cves" ])
    get "/api/v1/control_center/ansible/run_groups", headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "creates a single run group and never serializes execution secrets" do
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/run_groups", params: launch_params, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "queued", body["status"]
    assert_equal 1, body.fetch("runs").length
    assert_equal "Baseline", body.dig("runs", 0, "playbook_name")
    assert_secret_free(body)
  end

  test "returns launch validation errors without creating history" do
    sign_in_as(@user)
    @inventory.update!(known_hosts: nil, host_key_fingerprints: {})

    assert_no_difference -> { ControlCenter::Ansible::RunGroup.count } do
      post "/api/v1/control_center/ansible/run_groups", params: launch_params, as: :json
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert_includes body.dig("details", "inventory_id"), "must have approved host keys"
  end

  test "lists groups newest first with bounded page pagination" do
    older = launch
    older.update_column(:created_at, 2.hours.ago)
    newer = launch
    newer.update_column(:created_at, 1.hour.ago)
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/run_groups", params: { page: 1, limit: 1 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ newer.id ], body.fetch("run_groups").map { |group| group["id"] }
    assert_equal({ "page" => 1, "limit" => 1, "total" => 2 }, body.fetch("pagination"))
  end

  test "shows immutable group metadata and child summaries without sensitive keys" do
    group = launch
    group.runs.sole.update_columns(lease_digest: "digest-secret")
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/run_groups/#{group.id}"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal group.id, body["id"]
    assert_equal @inventory.name, body.dig("launch_snapshot", "inventory", "name")
    assert_equal group.runs.sole.id, body.dig("runs", 0, "id")
    assert_secret_free(body)
  end

  test "cancellation is idempotent while active and conflicts after terminal completion" do
    group = launch
    run = group.runs.sole
    group.update_columns(status: "running")
    run.update_columns(status: "running")
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/run_groups/#{group.id}/cancel", as: :json
    assert_response :success
    first_requested_at = group.reload.cancel_requested_at
    assert_equal "canceling", group.status
    assert_equal "canceling", run.reload.status

    post "/api/v1/control_center/ansible/run_groups/#{group.id}/cancel", as: :json
    assert_response :success
    assert_equal first_requested_at, group.reload.cancel_requested_at

    group.update_columns(status: "succeeded", completed_at: Time.current, execution_payload: nil)
    run.update_columns(status: "succeeded", completed_at: Time.current)
    post "/api/v1/control_center/ansible/run_groups/#{group.id}/cancel", as: :json
    assert_response :conflict
    assert_equal "conflict", JSON.parse(response.body)["error"]
  end

  test "executor health reports only Ansible-capable runners and queued age" do
    ansible, = Runner.generate(name: "ansible-one", kinds: [ "ansible" ])
    Runner.generate(name: "curl-one", kinds: [ "curl" ])
    ansible.update_column(:last_seen_at, 30.seconds.ago)
    group = launch
    group.runs.sole.update_columns(status: "running", runner_id: ansible.id)
    launch
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/executor_health"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["configured_runners"]
    assert_equal 1, body["active_runners"]
    assert body["last_seen_at"].present?
    assert_operator body["oldest_queued_age_seconds"], :>=, 0
    refute_includes response.body, ansible.token_digest
  end

  test "cookie-authenticated launch remains CSRF protected" do
    sign_in_as(@user)
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post "/api/v1/control_center/ansible/run_groups", params: launch_params, as: :json

    assert_response :forbidden
    assert_equal "invalid_csrf_token", JSON.parse(response.body)["error"]
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  private

  def launch
    ControlCenter::Ansible::SingleLaunch.call(user: @user, **launch_params.symbolize_keys)
  end

  def launch_params
    {
      playbook_id: @playbook.id,
      inventory_id: @inventory.id,
      credential_id: @credential.id,
      variable_set_ids: [],
      overrides: [],
      host_limit: nil,
      check_mode: false,
      timeout_seconds: 3600
    }
  end

  def assert_secret_free(value)
    serialized = JSON.generate(value)
    refute_match(/password|private_key|execution_payload|lease_digest/i, serialized)
    refute_includes serialized, "fleet-secret"
  end
end
