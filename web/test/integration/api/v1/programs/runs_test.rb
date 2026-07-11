require "test_helper"

class Api::V1::Programs::RunsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def make(**attrs)
    ScopeRun.create!({ kind: "fetch", started_at: Time.current }.merge(attrs))
  end

  test "requires authentication" do
    get api_v1_programs_runs_path
    assert_response :unauthorized
  end

  test "lists all runs, newest first; mine=1 narrows to the current user" do
    sign_in_as(@user)
    mine = make(user: @user, started_at: 1.minute.ago)
    system_run = make(user: nil, started_at: 2.minutes.ago)

    get api_v1_programs_runs_path
    assert_equal [mine.id, system_run.id], response.parsed_body["runs"].map { |r| r["id"] }

    get api_v1_programs_runs_path, params: { mine: "1" }
    assert_equal [mine.id], response.parsed_body["runs"].map { |r| r["id"] }
  end

  test "status=ok filters to successful runs" do
    sign_in_as(@user)
    ok = make(success: true, finished_at: Time.current)
    make(success: false, finished_at: Time.current)

    get api_v1_programs_runs_path, params: { status: "ok" }
    ids = response.parsed_body["runs"].map { |r| r["id"] }
    assert_equal [ok.id], ids
  end

  test "since_id also re-pulls in-flight rows so they update" do
    sign_in_as(@user)
    finished = make(finished_at: Time.current)
    inflight = make(finished_at: nil) # older id path still returned because in-flight

    get api_v1_programs_runs_path, params: { since_id: [finished.id, inflight.id].max }
    ids = response.parsed_body["runs"].map { |r| r["id"] }
    assert_includes ids, inflight.id
  end

  test "show hides another user's run but exposes system runs" do
    other = User.create!(username: "someone-else", password: "password123")
    theirs = make(user: other)
    system_run = make(user: nil)
    sign_in_as(@user)

    get api_v1_programs_path(theirs.id)
    assert_response :not_found

    get api_v1_programs_path(system_run.id)
    assert_response :success
    assert_equal system_run.id, response.parsed_body["id"]
  end
end
