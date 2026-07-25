require "test_helper"

class Api::V1::AnsibleExecutorRunsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @runner, @token = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    @headers = { "Authorization" => "Bearer #{@token}" }
  end

  test "machine endpoints reject users API tokens malformed auth and non-Ansible runners" do
    post "/api/v1/ansible_executor/runs/claim", as: :json
    assert_response :unauthorized

    _api_token, api_raw = ApiToken.generate(user: @user, name: "control", scopes: [ "control_center" ])
    post "/api/v1/ansible_executor/runs/claim",
      headers: { "Authorization" => "Bearer #{api_raw}" }, as: :json
    assert_response :unauthorized

    post "/api/v1/ansible_executor/runs/claim",
      headers: { "Authorization" => "Bearer #{@token}, Bearer other" }, as: :json
    assert_response :unauthorized

    _curl, curl_token = Runner.generate(name: "curl", kinds: [ "curl" ])
    post "/api/v1/ansible_executor/runs/claim",
      headers: { "Authorization" => "Bearer #{curl_token}" }, as: :json
    assert_response :forbidden
    assert_equal "insufficient_capability", JSON.parse(response.body)["error"]
  end

  test "session cookies cannot authenticate machine endpoints" do
    sign_in_as(@user)

    post "/api/v1/ansible_executor/runs/claim", as: :json

    assert_response :unauthorized
  end

  test "claims distinct work and returns decrypted payload only on the claim response" do
    first = create_queued_run(queued_at: 2.minutes.ago, secret: "first-secret")
    second = create_queued_run(queued_at: 1.minute.ago, secret: "second-secret")

    post "/api/v1/ansible_executor/runs/claim", headers: @headers, as: :json
    assert_response :success
    first_body = JSON.parse(response.body)
    assert_equal first.id, first_body["id"]
    assert_equal "first-secret", first_body.dig("payload", "secrets", "ssh_password")
    lease = first_body.fetch("lease")
    refute_equal lease, first.reload.lease_digest

    post "/api/v1/ansible_executor/runs/claim", headers: @headers, as: :json
    assert_response :success
    assert_equal second.id, JSON.parse(response.body)["id"]

    post "/api/v1/ansible_executor/runs/claim", headers: @headers, as: :json
    assert_response :no_content

    post "/api/v1/ansible_executor/runs/#{first.id}/heartbeat",
      headers: @headers.merge("X-Ansible-Lease" => lease), as: :json
    assert_response :success
    refute_includes response.body, "first-secret"
    refute_match(/execution_payload|lease_digest|password|private_key/i, response.body)
  end

  test "start heartbeat cancellation control events and terminal result enforce one lease" do
    run = create_queued_run(secret: "fleet-secret")
    lease = claim(run)

    post "/api/v1/ansible_executor/runs/#{run.id}/start",
      headers: @headers.merge("X-Ansible-Lease" => "wrong"), as: :json
    assert_response :conflict
    assert_equal "lease_conflict", JSON.parse(response.body)["error"]

    lease_headers = @headers.merge("X-Ansible-Lease" => lease)
    post "/api/v1/ansible_executor/runs/#{run.id}/start", headers: lease_headers, as: :json
    assert_response :success
    assert_equal "running", run.reload.status

    old_expiry = run.lease_expires_at
    travel 5.seconds do
      post "/api/v1/ansible_executor/runs/#{run.id}/heartbeat", headers: lease_headers, as: :json
      assert_response :success
      assert_operator run.reload.lease_expires_at, :>, old_expiry
    end

    run.run_group.update_columns(cancel_requested_at: Time.current, status: "canceling")
    get "/api/v1/ansible_executor/runs/#{run.id}/control", headers: lease_headers
    assert_response :success
    assert_equal true, JSON.parse(response.body)["cancel_requested"]

    events = [ {
      event_uuid: "event-1", counter: 1, event_type: "runner_on_ok",
      stdout: "fleet-secret was used", event_data: { token: "fleet-secret" }
    } ]
    post "/api/v1/ansible_executor/runs/#{run.id}/events",
      params: { events: }, headers: lease_headers, as: :json
    assert_response :success
    assert_equal "[FILTERED] was used", run.run_events.sole.stdout

    post "/api/v1/ansible_executor/runs/#{run.id}/events",
      params: { events: }, headers: lease_headers, as: :json
    assert_response :success
    assert_equal 1, run.run_events.count

    result = {
      status: "canceled", exit_status: nil,
      ok_count: 1, changed_count: 0, failed_count: 0, unreachable_count: 0
    }
    post "/api/v1/ansible_executor/runs/#{run.id}/result",
      params: result, headers: lease_headers, as: :json
    assert_response :success
    assert_equal "canceled", run.reload.status
    assert_nil run.run_group.reload.execution_payload
    refute_includes response.body, "fleet-secret"

    post "/api/v1/ansible_executor/runs/#{run.id}/result",
      params: result, headers: lease_headers, as: :json
    assert_response :success
    post "/api/v1/ansible_executor/runs/#{run.id}/result",
      params: result.merge(status: "succeeded", exit_status: 0), headers: lease_headers, as: :json
    assert_response :conflict
    assert_equal "result_conflict", JSON.parse(response.body)["error"]
  end

  test "rejects oversized event bodies before ingestion" do
    run = create_queued_run
    lease = claim(run)

    post "/api/v1/ansible_executor/runs/#{run.id}/events",
      params: { events: [ { event_uuid: "large", counter: 1, event_type: "ok", stdout: "x" * 1.1.megabytes } ] },
      headers: @headers.merge("X-Ansible-Lease" => lease), as: :json

    assert_response :content_too_large
    assert_equal "payload_too_large", JSON.parse(response.body)["error"]
    assert_equal 0, run.run_events.count
  end

  private

  def claim(run)
    post "/api/v1/ansible_executor/runs/claim", headers: @headers, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal run.id, body["id"]
    body.fetch("lease")
  end

  def create_queued_run(queued_at: Time.current, secret: "fleet-secret")
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: @user,
      execution_payload: {
        "schema_version" => 1,
        "secrets" => { "ssh_password" => secret },
        "variables" => {},
        "options" => { "timeout_seconds" => 3600 }
      }
    )
    group.runs.create!(
      position: 0,
      status: "queued",
      playbook_yaml: "--- playbook",
      inventory_yaml: "--- inventory",
      known_hosts: "known hosts",
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600,
      queued_at:,
      claim_deadline: 5.minutes.from_now
    )
  end
end
