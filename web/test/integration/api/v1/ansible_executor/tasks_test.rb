require "test_helper"

class Api::V1::AnsibleExecutorTasksTest < ActionDispatch::IntegrationTest
  setup do
    @runner, @token = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    @headers = { "Authorization" => "Bearer #{@token}" }
  end

  test "claims heartbeats and finalizes utility work without redisclosing payload" do
    task = ControlCenter::Ansible::ExecutorTask.create!(
      kind: "syntax_check",
      created_by: users(:one),
      execution_payload: { "yaml" => "private task material" },
      claim_deadline: 5.minutes.from_now
    )

    post "/api/v1/ansible_executor/tasks/claim", headers: @headers, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal task.id, body["id"]
    assert_equal "private task material", body.dig("payload", "yaml")
    lease_headers = @headers.merge("X-Ansible-Lease" => body.fetch("lease"))

    post "/api/v1/ansible_executor/tasks/#{task.id}/heartbeat", headers: lease_headers, as: :json
    assert_response :success
    refute_includes response.body, "private task material"

    post "/api/v1/ansible_executor/tasks/#{task.id}/result",
      params: { status: "succeeded", result: { valid: true } }, headers: lease_headers, as: :json
    assert_response :success
    assert_equal "succeeded", task.reload.status
    assert_nil task.execution_payload
    assert_equal true, task.result["valid"]
    refute_includes response.body, "private task material"
  end

  test "returns no content when no utility work is queued" do
    post "/api/v1/ansible_executor/tasks/claim", headers: @headers, as: :json

    assert_response :no_content
  end

  test "wrong and stale leases are stable conflicts" do
    task = ControlCenter::Ansible::ExecutorTask.create!(
      kind: "syntax_check",
      status: "running",
      created_by: users(:one),
      runner: @runner,
      lease_digest: Digest::SHA256.hexdigest("correct"),
      lease_expires_at: 1.second.ago,
      claim_deadline: 5.minutes.from_now
    )

    post "/api/v1/ansible_executor/tasks/#{task.id}/heartbeat",
      headers: @headers.merge("X-Ansible-Lease" => "wrong"), as: :json

    assert_response :conflict
    assert_equal "lease_conflict", JSON.parse(response.body)["error"]
  end
end
