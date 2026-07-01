require "test_helper"

class Vulnerabilities::RunsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @doc = { "id" => "abc", "poc" => { "curl" => "curl https://example.com" } }
  end

  test "unauthenticated create redirects to sign in" do
    post "/vulnerabilities/abc/runs"
    assert_response :redirect
  end

  test "create enqueues a curl job and returns a turbo stream" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: @doc) do
      assert_difference -> { RunnerJob.count }, 1 do
        post "/vulnerabilities/abc/runs", headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end
    assert_response :success
    job = RunnerJob.last
    assert_equal "queued", job.status
    assert_equal "abc", job.vulnerability_id
    assert_equal @user.id, job.requested_by_id
  end

  test "create with an invalid curl records a failed job" do
    sign_in_as(@user)
    bad = { "id" => "abc", "poc" => { "curl" => "curl file:///etc/passwd" } }
    stub_methods(Vulnerabilities::MongoSource, find: bad) do
      post "/vulnerabilities/abc/runs", headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
    assert_response :success
    assert_equal "failed", RunnerJob.last.status
  end

  test "create 404s when the vuln is missing" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: nil) do
      post "/vulnerabilities/abc/runs"
    end
    assert_response :not_found
  end

  test "create 422s when there is no curl poc" do
    sign_in_as(@user)
    stub_methods(Vulnerabilities::MongoSource, find: { "id" => "abc", "poc" => {} }) do
      post "/vulnerabilities/abc/runs"
    end
    assert_response :unprocessable_entity
  end

  test "show renders the job frame and reaps a stale job" do
    sign_in_as(@user)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "abc", requested_by: @user, status: "running", started_at: 1.hour.ago)
    get "/vulnerabilities/abc/runs/#{job.id}"
    assert_response :success
    assert_equal "failed", job.reload.status
  end

  test "show returns 404 when the job belongs to a different user" do
    other_user = users(:two)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "abc", requested_by: other_user, status: "queued")
    sign_in_as(@user)
    get "/vulnerabilities/abc/runs/#{job.id}"
    assert_response :not_found
  end
end
