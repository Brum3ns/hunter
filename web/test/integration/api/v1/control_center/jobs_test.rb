require "test_helper"

class Api::V1::ControlCenter::JobsTest < ActionDispatch::IntegrationTest
  W = ControlCenter::WhiterabbitCommand
  setup do
    @user = users(:one)
    @template = ControlCenter::Template.create!(name: "probe", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }])
  end

  test "requires auth" do
    post "/api/v1/control_center/jobs", params: { template: "probe" }, as: :json
    assert_response :unauthorized
  end

  test "submit records a succeeded job and returns its output" do
    sign_in_as(@user)
    ok = ->(template:, targets:, queue_name:, target_chunk: 0, delay: 0) { W::Result.new(exit_status: 0, stdout: "sent 2", stderr: "", error: nil) }
    stub_methods(ControlCenter::Standalone, submit: ok) do
      post "/api/v1/control_center/jobs", params: { template: "probe", targets: %w[a.com b.com], queue_name: "scan" }, as: :json
    end
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "succeeded", body["status"]
    assert_equal 2, body["target_count"]
    assert_equal "sent 2", body["stdout"]
    assert_equal 1, ControlCenter::Job.where(status: "succeeded").count
  end

  test "submit records a failed job when the binary errors" do
    sign_in_as(@user)
    bad = ->(**) { W::Result.new(exit_status: 1, stdout: "", stderr: "boom", error: nil) }
    stub_methods(ControlCenter::Standalone, submit: bad) do
      post "/api/v1/control_center/jobs", params: { template: "probe", targets: ["a.com"] }, as: :json
    end
    assert_response :created
    assert_equal "failed", JSON.parse(response.body)["status"]
  end

  test "submit 404s for an unknown template" do
    sign_in_as(@user)
    post "/api/v1/control_center/jobs", params: { template: "nope", targets: ["a.com"] }, as: :json
    assert_response :not_found
  end

  test "index lists jobs newest first" do
    sign_in_as(@user)
    ControlCenter::Job.create!(template_name: "probe", status: "succeeded", target_count: 1)
    get "/api/v1/control_center/jobs"
    assert_response :success
    assert_equal 1, JSON.parse(response.body)["jobs"].length
  end
end
