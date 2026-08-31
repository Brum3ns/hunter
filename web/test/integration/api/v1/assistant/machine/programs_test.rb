require "test_helper"

class Api::V1::Assistant::Machine::ProgramsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "programs-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "list_programs returns a bounded projection and count" do
    program = Program.new(program_data)
    result = Programs::Query::Result.new(programs: [ program ], total: 1)

    stub_methods(Programs::Query, call: result) do
      get "/api/v1/assistant/machine/programs", params: { q: "acme" }, headers: headers
    end

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    item = body["items"].first
    assert_equal %w[sid name platform public bounty_range favorited trashed last_viewed_at], item.keys
    assert_equal "acme-corp", item["sid"]
    assert_equal "hackerone", item["platform"]
    assert_equal true, item["public"]
  end

  test "list_programs exposes this turn user's favorite trash and view state and filters trash" do
    user = assistant_turns(:created).user
    user.favorites.create!(program_sid: "acme-corp")
    user.trashes.create!(program_sid: "acme-corp")
    user.program_views.create!(program_sid: "acme-corp", viewed_at: Time.zone.parse("2026-07-30 10:00 UTC"))
    captured = nil
    result = Programs::Query::Result.new(programs: [ Program.new(program_data) ], total: 1)

    stub_methods(Programs::Query, call: ->(qp) { captured = qp; result }) do
      get "/api/v1/assistant/machine/programs", params: { trash_only: "yes" }, headers: headers
    end

    assert_response :success
    item = response.parsed_body.fetch("items").sole
    assert_equal true, item["favorited"]
    assert_equal true, item["trashed"]
    assert_equal "2026-07-30T10:00:00.000Z", item["last_viewed_at"]
    assert_equal "yes", captured[:trash_only]
    assert_equal user.favorite_sids, captured[:_favorited_sids]
    assert_equal user.trash_sids, captured[:_trashed_sids]
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
      }, headers: headers
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

  test "list_programs is refused when its live capability is disabled" do
    Assistant::Setting.instance.update!(disabled_capability_tools: [ "list_programs" ])

    get "/api/v1/assistant/machine/programs", headers: headers

    assert_response :forbidden
    assert_equal "capability_disabled", response.parsed_body["error"]
  end

  test "get_program returns the full projection" do
    program = Program.new(program_data)

    stub_methods(Programs::Source, find: program) do
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers
    end

    assert_response :success
    result = response.parsed_body["program"]
    expected_keys = %w[
      sid name platform public bounty_range favorited trashed last_viewed_at
      slug url vdp bounty bounty_min bounty_max currency reward_avg reward_max
      report_count reports_24h reports_7d reports_month avg_response_hrs
      scope_count collaboration tags languages date status description description_redacted
      organization reward_grid hall_of_fame hacktivity rules rules_redacted
      qualifying_vulnerabilities non_qualifying_vulnerabilities account_access
      account_access_redacted required_user_agent restricted_ips vpn_active vpn_ips
      scope out_of_scope
    ]
    assert_equal expected_keys, result.keys
    assert_equal "acme-corp", result["slug"]
    assert_equal [ {
      "asset" => "example.com", "type" => "web", "type_name" => nil, "value" => nil,
      "bounty" => nil, "inscope" => nil, "report_count" => nil
    } ], result["scope"]
    assert_equal [ {
      "asset" => "internal.example.com", "type" => "web", "type_name" => nil, "value" => nil,
      "bounty" => nil, "inscope" => nil, "report_count" => nil
    } ], result["out_of_scope"]
  end

  test "get_program exposes useful plain data but never raw HTML or source containers" do
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
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers
    end

    assert_response :success
    result = response.parsed_body["program"]
    expected_keys = %w[
      sid name platform public bounty_range favorited trashed last_viewed_at
      slug url vdp bounty bounty_min bounty_max currency reward_avg reward_max
      report_count reports_24h reports_7d reports_month avg_response_hrs
      scope_count collaboration tags languages date status description description_redacted
      organization reward_grid hall_of_fame hacktivity rules rules_redacted
      qualifying_vulnerabilities non_qualifying_vulnerabilities account_access
      account_access_redacted required_user_agent restricted_ips vpn_active vpn_ips
      scope out_of_scope
    ]
    assert_equal expected_keys, result.keys
    assert_equal "a very long description that should never leak", result["description"]
    assert_equal [ "xss" ], result["qualifying_vulnerabilities"]
    assert_equal [ "10.0.0.2" ], result["vpn_ips"]
    refute_includes response.body, "<p>rules</p>"
    refute_includes response.body, "<p>access</p>"
    refute result.key?("raw")
  end

  test "get_program normalizes nested reward and scope scalars to the broker contract" do
    data = program_data.merge(
      "reward_grid" => { "low" => "100.5", "medium" => "not-a-number" },
      "scope" => [ {
        "asset" => "example.com", "type" => "web", "bounty" => true,
        "inscope" => false, "report_count" => "7"
      } ]
    )

    stub_methods(Programs::Source, find: Program.new(data)) do
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers
    end

    assert_response :success
    program = response.parsed_body.fetch("program")
    assert_equal 100.5, program.dig("reward_grid", "low")
    assert_nil program.dig("reward_grid", "medium")
    assert_equal true, program.dig("scope", 0, "bounty")
    assert_equal false, program.dig("scope", 0, "inscope")
    assert_equal 7, program.dig("scope", 0, "report_count")
  end

  test "get_program releases the reservation on a miss" do
    stub_methods(Programs::Source, find: nil) do
      get "/api/v1/assistant/machine/programs/does-not-exist", headers: headers
    end

    assert_response :not_found
  end

  test "an aggregate projection above the encoded result ceiling fails closed" do
    oversized_scope = Array.new(900) do |index|
      { "asset" => "#{index}-#{"a" * 4_000}.example", "type" => "web" }
    end

    stub_methods(Programs::Source, find: Program.new(program_data.merge("scope" => oversized_scope))) do
      get "/api/v1/assistant/machine/programs/acme-corp", headers: headers
    end

    assert_response :content_too_large
    assert_equal "tool_response_rejected", response.parsed_body["error"]
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

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
