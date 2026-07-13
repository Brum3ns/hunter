require "test_helper"

class Api::V1::Runner::JobsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @runner, @raw = Runner.generate(name: "curl-runner", kinds: %w[curl])
  end

  def auth = { "Authorization" => "Bearer #{@raw}" }

  def queue(kind: "curl")
    RunnerJob.create!(kind: kind, command: "curl https://example.com", vulnerability_id: "v1", requested_by: @user)
  end

  test "claim requires a runner bearer token" do
    post "/api/v1/runner/jobs/claim"
    assert_response :unauthorized
  end

  test "a user API token cannot claim" do
    _, raw = ApiToken.generate(user: @user, name: "t")
    post "/api/v1/runner/jobs/claim", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :unauthorized
  end

  test "claim returns the oldest queued job and marks it running" do
    job = queue
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal job.id, body["id"]
    assert_equal "curl", body["kind"]
    assert_equal "running", job.reload.status
  end

  test "claim returns 204 when nothing is queued" do
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :no_content
  end

  test "claim never returns an out-of-scope kind" do
    RunnerJob.insert!({ kind: "nuclei", command: "x", vulnerability_id: "v", requested_by_id: @user.id, status: "queued", created_at: Time.current, updated_at: Time.current })
    post "/api/v1/runner/jobs/claim", headers: auth
    assert_response :no_content
  end

  test "result records terminal state for an owned running job" do
    job = queue
    RunnerJob.claim!(@runner)
    post "/api/v1/runner/jobs/#{job.id}/result", headers: auth,
      params: { exit_status: 0, stdout: "ok", stderr: "", duration_ms: 5, output_truncated: false }
    assert_response :success
    assert_equal "succeeded", job.reload.status
  end

  test "result 404s for a job the runner did not claim" do
    other, = Runner.generate(name: "other", kinds: %w[curl])
    job = queue
    RunnerJob.claim!(other)
    post "/api/v1/runner/jobs/#{job.id}/result", headers: auth,
      params: { exit_status: 0, stdout: "x", stderr: "", duration_ms: 1 }
    assert_response :not_found
    assert_equal "running", job.reload.status
  end
end
