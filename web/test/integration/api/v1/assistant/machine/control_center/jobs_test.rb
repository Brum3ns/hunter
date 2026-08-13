require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::JobsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-jobs-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_jobs returns a bounded projection ordered by created_at desc" do
    older = job(template_name: "probe-a", created_at: 2.hours.ago)
    newer = job(template_name: "probe-b", created_at: 1.hour.ago)

    get "/api/v1/assistant/machine/control_center/jobs", headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    ids = body["items"].map { |i| i["id"] }
    assert_equal [ newer.id, older.id ], ids
    item = body["items"].first
    assert_equal %w[id template_name status queue_name target_count exit_status created_at], item.keys
  end

  test "list_jobs is refused without the control_center_jobs scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/control_center/jobs", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "list_jobs narrows by the status filter" do
    job(template_name: "a", status: "succeeded")
    job(template_name: "b", status: "failed")

    get "/api/v1/assistant/machine/control_center/jobs", params: { status: "failed" }, headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    assert_equal "b", body["items"].first["template_name"]
  end

  test "get_job returns a safe operational summary without raw internal targeting fields" do
    record = job(
      template_name: "probe", status: "succeeded", queue_name: "test", target_count: 3,
      exit_status: 0,
      stdout: "ok\nAuthorization: Bearer do-not-return",
      stderr: "Cookie: session=do-not-return",
      template_snapshot: { "name" => "probe", "commands" => [] },
      selections: [ { "source" => "targets", "mode" => "filter", "q" => "host:*.example.com" } ],
      manual_targets: [ "manual.example.com" ],
      idempotency_key: "secret-key", created_by: "hunter",
      target_chunk: 100, job_delay_ms: 250
    )

    get "/api/v1/assistant/machine/control_center/jobs/#{record.id}", headers: headers(read_grant)

    assert_response :success
    result = response.parsed_body["job"]
    expected_keys = %w[
      id template_name status queue_name target_count exit_status created_at
      created_by target_chunk job_delay_ms selection_count manual_target_count selection_sources
      stdout stdout_redacted stderr stderr_redacted updated_at
    ]
    assert_equal expected_keys, result.keys
    assert_equal "probe", result["template_name"]
    assert_equal "hunter", result["created_by"]
    assert_equal 1, result["selection_count"]
    assert_equal 1, result["manual_target_count"]
    assert_equal [ "targets" ], result["selection_sources"]
    assert_includes result["stdout"], "Authorization: [REDACTED]"
    assert_equal true, result["stdout_redacted"]
    assert_equal true, result["stderr_redacted"]
    refute_includes response.body, "do-not-return"
    %w[template_snapshot selections manual_targets idempotency_key].each do |forbidden|
      refute result.key?(forbidden), "expected #{forbidden} to be excluded from the projection"
    end
  end

  test "get_job releases the reservation on a miss" do
    get "/api/v1/assistant/machine/control_center/jobs/999999999", headers: headers(read_grant)

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def job(template_name:, status: "queued", queue_name: "test", target_count: 0, exit_status: nil,
           stdout: nil, stderr: nil, created_at: Time.current, template_snapshot: {}, selections: [],
           manual_targets: [], idempotency_key: nil, created_by: nil, target_chunk: 0, job_delay_ms: 0)
    ::ControlCenter::Job.create!(
      template_name: template_name, status: status, queue_name: queue_name, target_count: target_count,
      exit_status: exit_status, stdout: stdout, stderr: stderr, created_at: created_at,
      template_snapshot: template_snapshot, selections: selections, manual_targets: manual_targets,
      idempotency_key: idempotency_key, created_by: created_by,
      target_chunk: target_chunk, job_delay_ms: job_delay_ms
    )
  end

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_jobs", "get_job" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
