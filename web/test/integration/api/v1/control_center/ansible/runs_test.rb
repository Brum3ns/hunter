require "test_helper"

class Api::V1::ControlCenter::Ansible::RunsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    credential = ControlCenter::Ansible::Credential.create!(
      name: "Deploy", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: @user
    )
    inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers",
      yaml_content: "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.10.0.8\n",
      default_credential: credential,
      known_hosts: "worker ssh-ed25519 AAAA",
      host_key_fingerprints: { "worker" => "SHA256:ok" },
      created_by: @user
    )
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Baseline", yaml_content: "---\n- hosts: workers\n  tasks: []\n", created_by: @user
    )
    @group = ControlCenter::Ansible::SingleLaunch.call(
      user: @user, playbook_id: playbook.id, inventory_id: inventory.id,
      credential_id: credential.id, variable_set_ids: [], overrides: [],
      host_limit: nil, check_mode: false, timeout_seconds: 3600
    )
    @run = @group.runs.sole
  end

  test "shows one run without payload lease or secret fields" do
    @run.update_columns(lease_digest: "lease-secret")
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/runs/#{@run.id}"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal @run.id, body["id"]
    assert_equal @group.id, body["run_group_id"]
    assert_equal "Baseline", body["playbook_name"]
    refute_match(/password|private_key|execution_payload|lease_digest/i, response.body)
    refute_includes response.body, "fleet-secret"
  end

  test "paginates ordered events by counter" do
    @run.run_events.create!(event_uuid: "three", counter: 3, event_type: "runner_on_ok", stdout: "third")
    @run.run_events.create!(event_uuid: "one", counter: 1, event_type: "playbook_on_start", stdout: "first")
    @run.run_events.create!(event_uuid: "two", counter: 2, event_type: "runner_on_ok", stdout: "second")
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/runs/#{@run.id}/events", params: { after_counter: 1, limit: 1 }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal [ 2 ], body.fetch("events").map { |event| event["counter"] }
    assert_equal 2, body["next_counter"]
  end

  test "run cancellation is idempotent while active and terminal runs conflict" do
    @group.update_columns(status: "running")
    @run.update_columns(status: "running")
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/runs/#{@run.id}/cancel", as: :json
    assert_response :success
    requested_at = @run.reload.cancel_requested_at
    assert_equal "canceling", @run.status

    post "/api/v1/control_center/ansible/runs/#{@run.id}/cancel", as: :json
    assert_response :success
    assert_equal requested_at, @run.reload.cancel_requested_at

    @run.update_columns(status: "failed", completed_at: Time.current)
    post "/api/v1/control_center/ansible/runs/#{@run.id}/cancel", as: :json
    assert_response :conflict
  end

  test "returns not found for unknown runs and event parents" do
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/runs/0"
    assert_response :not_found
    get "/api/v1/control_center/ansible/runs/0/events"
    assert_response :not_found
  end
end
