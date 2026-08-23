require "test_helper"

class Api::V1::Assistant::Machine::WorkflowReadsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "workflow-reads-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "target analysis aggregates the complete matching selection in one call" do
    docs = Array.new(57) do |index|
      {
        "id" => index.to_s,
        "tech" => index < 40 ? [ "nginx", "ruby" ] : [ "apache" ],
        "http" => { "status_code" => index < 50 ? 200 : 404, "webserver" => index < 40 ? "nginx" : "apache" },
        "metadata" => { "program" => "acme" }
      }
    end

    stub_methods(Targets::MongoSource, all: docs, count: 57) do
      post "/api/v1/assistant/machine/targets/analyze",
        params: { q: "program:acme" }, headers: headers(grant("analyze_targets")), as: :json
    end

    assert_response :success
    assert_equal 57, response.parsed_body.fetch("count")
    assert_equal 57, response.parsed_body.fetch("analyzed_count")
    assert_equal({ "value" => "nginx", "count" => 40 },
      response.parsed_body.fetch("technology_counts").first)
    assert_equal false, response.parsed_body.fetch("truncated")
  end

  test "program changes and scope runs remain bounded and human attributed" do
    change = ProgramChange.create!(
      user: machine_user, kind: "scope_added", program_sid: "acme", program_name: "Acme",
      platform: "hackerone", detected_at: Time.current,
      old_value: nil, new_value: { "asset" => "api.example.test" }
    )
    run = ScopeRun.create!(
      user: machine_user, kind: "fetch", trigger: "manual", platform: "hackerone",
      started_at: Time.current, finished_at: Time.current, success: true
    )

    get "/api/v1/assistant/machine/programs/changes",
      headers: headers(grant("list_program_changes"))
    assert_response :success
    assert_equal change.id, response.parsed_body.fetch("items").sole.fetch("id")

    get "/api/v1/assistant/machine/programs/scope_runs/#{run.id}",
      headers: headers(grant("get_scope_run"))
    assert_response :success
    assert_equal run.id, response.parsed_body.dig("scope_run", "id")
    assert_equal machine_user.username, response.parsed_body.dig("scope_run", "user")
  end

  test "new CVE feed returns the compact safe projection and cursor" do
    docs = [ {
      "id" => "CVE-2026-1234", "summary" => "Example", "severity_score" => 8.2,
      "has_fix" => true, "modified" => "2026-08-19T10:00:00Z",
      "first_seen_at" => "2026-08-19T11:00:00Z"
    } ]
    stub_methods(Cves::MongoSource, new_since: docs) do
      get "/api/v1/assistant/machine/cves/new",
        params: { since: "2026-08-19T00:00:00Z" }, headers: headers(grant("list_new_cves"))
    end

    assert_response :success
    assert_equal "CVE-2026-1234", response.parsed_body.fetch("items").sole.fetch("id")
    assert_equal "2026-08-19T11:00:00Z", response.parsed_body.fetch("next_since")
    assert_equal "CVE-2026-1234", response.parsed_body.fetch("next_since_id")
  end

  test "analysis request bodies are closed" do
    post "/api/v1/assistant/machine/targets/analyze",
      params: { q: "acme", method: "DELETE" }, headers: headers(grant("analyze_targets")), as: :json

    assert_response :unprocessable_content
    assert_equal "validation_failed", response.parsed_body.fetch("error")
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def grant(tool)
    Assistant::Grants::Issuer.call(turn: assistant_turns(:created), resources: [], tools: [ tool ])
  end

  def headers(raw_grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => raw_grant }
  end
end
