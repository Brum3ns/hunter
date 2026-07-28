require "test_helper"

class Api::V1::ControlCenter::JobsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:one)
  end

  def auth(raw) = { "Authorization" => "Bearer #{raw}" }

  test "requires auth" do
    post "/api/v1/control_center/jobs", params: { template: "probe" }, as: :json
    assert_response :unauthorized
  end

  test "create enqueues SubmitJob and returns a queued job (no inline whiterabbit)" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as(@user)
    assert_enqueued_with(job: ControlCenter::SubmitJob) do
      post "/api/v1/control_center/jobs", params: {
        template: "httpx", queue_name: "test", target_chunk: 100,
        selections: [{ source: "targets", mode: "filter", q: "host:*.example.com" }],
        targets: ["manual.example.com"]
      }, as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "queued", body["status"]
    job = ControlCenter::Job.find(body["id"])
    assert_equal ["manual.example.com"], job.manual_targets
    assert_equal "targets", job.selections.first["source"]
  end

  test "create with a malformed selection returns 400" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as(@user)
    post "/api/v1/control_center/jobs", params: {
      template: "httpx", selections: [{ source: "bogus" }]
    }, as: :json
    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["error"]
  end

  test "a repeated idempotency_key returns the existing job without a second enqueue" do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
    sign_in_as(@user)
    payload = { template: "httpx", idempotency_key: "abc", selections: [{ source: "targets", q: "x" }] }
    post "/api/v1/control_center/jobs", params: payload, as: :json
    first_id = JSON.parse(response.body)["id"]
    assert_no_enqueued_jobs(only: ControlCenter::SubmitJob) do
      post "/api/v1/control_center/jobs", params: payload, as: :json
    end
    assert_equal first_id, JSON.parse(response.body)["id"]
  end

  test "submit 404s for an unknown template" do
    sign_in_as(@user)
    post "/api/v1/control_center/jobs", params: { template: "nope", targets: ["a.com"] }, as: :json
    assert_response :not_found
  end

  test "resolve_targets returns a count and a bounded sample, not the full list" do
    sign_in_as(@user)
    stub_methods(ControlCenter::TargetSelection,
      validate!: true, count: 500_000, sample: %w[a.com b.com]) do
      post "/api/v1/control_center/jobs/resolve_targets", params: {
        selections: [{ source: "targets", q: "host:*.example.com" }]
      }, as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 500_000, body["count"]
    assert_equal false, body["truncated"]
    assert_equal %w[a.com b.com], body["sample"]
  end

  test "resolve_targets rejects a malformed selection with 400" do
    sign_in_as(@user)
    post "/api/v1/control_center/jobs/resolve_targets", params: {
      selections: [{ source: "bogus" }]
    }, as: :json
    assert_response :bad_request
    assert_equal "bad_request", JSON.parse(response.body)["error"]
  end

  test "index lists jobs newest first" do
    sign_in_as(@user)
    ControlCenter::Job.create!(template_name: "probe", status: "succeeded", target_count: 1)
    get "/api/v1/control_center/jobs"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["jobs"].length
  end

  test "control_center scope is enforced for bearer tokens on jobs" do
    _rec, raw = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"])
    get "/api/v1/control_center/jobs", headers: auth(raw)
    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end
end
