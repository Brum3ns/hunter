require "test_helper"

class Vulnerabilities::StatusesTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }
  Source = Vulnerabilities::MongoSource

  DOC = {
    "id" => "abc",
    "finding" => { "name" => "XSS", "severity" => "high" },
    "report"  => { "status" => "triage" }
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    patch vulnerabilities_status_path("abc"), params: { status: "triage" }
    assert_redirected_to new_session_path
  end

  test "updates status and renders a turbo stream refreshing every status cell" do
    sign_in_as(@user)
    captured = nil
    stub = ->(id:, status:, user:) { captured = { id: id, status: status, user: user }; DOC }

    stub_methods(Source, update_status: stub) do
      patch vulnerabilities_status_path("abc"), params: { status: "triage" }, as: :turbo_stream
    end

    assert_response :success
    assert_equal "abc",    captured[:id]
    assert_equal "triage", captured[:status]
    assert_equal @user,    captured[:user]
    assert_select "turbo-stream[action=update][targets='.status-cell-abc']"
  end

  test "returns 400 for an invalid status" do
    sign_in_as(@user)
    stub_methods(Source, update_status: ->(**) { raise ArgumentError }) do
      patch vulnerabilities_status_path("abc"), params: { status: "bogus" }, as: :turbo_stream
    end
    assert_response :bad_request
  end

  test "returns 404 when the vulnerability is not found" do
    sign_in_as(@user)
    stub_methods(Source, update_status: nil) do
      patch vulnerabilities_status_path("missing"), params: { status: "triage" }, as: :turbo_stream
    end
    assert_response :not_found
  end
end
