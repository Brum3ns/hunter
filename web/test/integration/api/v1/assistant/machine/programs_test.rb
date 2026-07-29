require "test_helper"

class Api::V1::Assistant::Machine::ProgramsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "programs-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_programs returns a bounded projection and count" do
    program = Program.new(program_data)
    result = Programs::Query::Result.new(programs: [ program ], total: 1)

    stub_methods(Programs::Query, call: result) do
      get "/api/v1/assistant/machine/programs", params: { q: "acme" }, headers: headers(read_grant)
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[sid name platform public bounty_range], item.keys
    assert_equal "acme-corp", item["sid"]
    assert_equal "hackerone", item["platform"]
    assert_equal true, item["public"]
  end

  test "list_programs passes filters, q, and pagination through to Programs::Query.call" do
    captured = nil
    result = Programs::Query::Result.new(programs: [], total: 0)

    stub_methods(Programs::Query, call: ->(qp) { captured = qp; result }) do
      get "/api/v1/assistant/machine/programs", params: {
        q: "acme asset:example.com",
        status: "public",
        bounty: "with",
        collaboration: "yes",
        scope_count_gte: "2",
        scope_count_lte: "10",
        reports_gte: "5",
        sort: "name",
        dir: "asc",
        platforms: "hackerone,bugcrowd",
        scope_types: [ "web", "android" ],
        page: "2",
        limit: "10"
      }, headers: headers(read_grant)
    end

    assert_response :success
    assert_equal "public", captured[:status]
    assert_equal "with", captured[:bounty]
    assert_equal "yes", captured[:collaboration]
    assert_equal "2", captured[:scope_count_gte]
    assert_equal "10", captured[:scope_count_lte]
    assert_equal "5", captured[:reports_gte]
    assert_equal "name", captured[:sort]
    assert_equal "asc", captured[:dir]
    assert_equal %w[hackerone bugcrowd], captured[:platforms]
    assert_equal %w[web android], captured[:scope_types]
    assert_equal "acme", captured[:q]
    assert_kind_of Programs::DorkExpression::Term, captured[:dork_expression]
    assert_equal 2, captured[:page]
    assert_equal 10, captured[:per_page]
  end

  test "list_programs is refused without the programs scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/programs", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "get_program returns the full projection" do
    program = Program.new(program_data)

    stub_methods(Programs::Source, find: program) do
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers(read_grant)
    end

    assert_response :success
    result = response.parsed_body["program"]
    expected_keys = %w[
      sid name platform public bounty_range
      slug url vdp bounty bounty_min bounty_max currency reward_avg reward_max
      report_count reports_24h reports_7d reports_month avg_response_hrs
      scope_count collaboration tags languages scope out_of_scope
    ]
    assert_equal expected_keys, result.keys
    assert_equal "acme-corp", result["slug"]
    assert_equal [ { "asset" => "example.com", "type" => "web" } ], result["scope"]
    assert_equal [ { "asset" => "internal.example.com", "type" => "web" } ], result["out_of_scope"]
  end

  test "get_program's full payload excludes bloat/infra fields even when populated" do
    data = program_data.merge(
      "policy" => {
        "rules_html" => "<p>rules</p>",
        "account_access_html" => "<p>access</p>",
        "qualifying_vulnerabilities" => [ "xss" ],
        "non_qualifying_vulnerabilities" => [ "self-xss" ],
        "user_agent" => "HunterBot/1.0",
        "restricted_ips" => [ "10.0.0.1" ],
        "vpn_active" => true,
        "vpn_ips" => [ "10.0.0.2" ]
      },
      "description" => "a very long description that should never leak"
    )
    program = Program.new(data)

    stub_methods(Programs::Source, find: program) do
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers(read_grant)
    end

    assert_response :success
    result = response.parsed_body["program"]
    expected_keys = %w[
      sid name platform public bounty_range
      slug url vdp bounty bounty_min bounty_max currency reward_avg reward_max
      report_count reports_24h reports_7d reports_month avg_response_hrs
      scope_count collaboration tags languages scope out_of_scope
    ]
    assert_equal expected_keys, result.keys
    refute_includes response.body, "rules"
    refute_includes response.body, "very long description"
    refute_includes response.body, "10.0.0.2"
    refute_includes response.body, "xss"
  end

  test "get_program releases the reservation on a miss" do
    stub_methods(Programs::Source, find: nil) do
      get "/api/v1/assistant/machine/programs/does-not-exist", headers: headers(read_grant)
    end

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def program_data
    {
      "_sid" => "acme-corp",
      "slug" => "acme-corp",
      "name" => "Acme Corp",
      "platform" => "hackerone",
      "url" => "https://hackerone.com/acme-corp",
      "public" => true,
      "vdp" => false,
      "bounty" => true,
      "bounty_min" => 100.0,
      "bounty_max" => 5000.0,
      "currency" => "USD",
      "reward_avg" => 250.0,
      "reward_max" => 5000.0,
      "report_count" => 42,
      "Total_reports_last24_hours" => 1,
      "Total_reports_last7_days" => 3,
      "Total_reports_current_month" => 10,
      "Average_first_time_response" => 24,
      "scope_count" => 2,
      "collaboration" => false,
      "tags" => [ "web", "api" ],
      "languages" => [ "ruby" ],
      "scope" => [ { "asset" => "example.com", "type" => "web", "eligible_for_bounty" => true } ],
      "outofscope" => [ { "asset" => "internal.example.com", "type" => "web" } ]
    }
  end

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_programs", "get_program" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
