require "test_helper"

class Api::V1::Programs::ChangesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  def make(**attrs)
    ProgramChange.create!({ user: @user, kind: "program_added", detected_at: Time.current }.merge(attrs))
  end

  test "requires authentication" do
    get api_v1_programs_changes_path
    assert_response :unauthorized
  end

  test "returns the current user's changes, newest first" do
    sign_in_as(@user)
    a = make(program_name: "A", detected_at: 2.hours.ago)
    b = make(program_name: "B", detected_at: 1.minute.ago)

    get api_v1_programs_changes_path
    assert_response :success
    ids = response.parsed_body["changes"].map { |c| c["id"] }
    assert_equal [b.id, a.id], ids
  end

  test "never leaks another user's changes" do
    other = User.create!(username: "someone-else", password: "password123")
    ProgramChange.create!(user: other, kind: "program_added", detected_at: Time.current)
    sign_in_as(@user)

    get api_v1_programs_changes_path
    assert_empty response.parsed_body["changes"]
  end

  test "filters by platform and kind" do
    sign_in_as(@user)
    make(platform: "hackerone", kind: "bounty_changed")
    make(platform: "bugcrowd", kind: "program_added")

    get api_v1_programs_changes_path, params: { platform: "hackerone", kind: "bounty_changed" }
    rows = response.parsed_body["changes"]
    assert_equal 1, rows.length
    assert_equal "hackerone", rows.first["platform"]
  end

  test "since_id pulls only newer rows for the live tail" do
    sign_in_as(@user)
    first = make
    make # second, newer

    get api_v1_programs_changes_path, params: { since_id: first.id }
    ids = response.parsed_body["changes"].map { |c| c["id"] }
    assert_not_includes ids, first.id
    assert_equal 1, ids.length
  end
end
