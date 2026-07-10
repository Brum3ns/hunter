require "test_helper"

class ProgramsOverviewTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:one)) }

  test "renders the programs catalog with a stubbed result" do
    result = Programs::Query::Result.new(
      programs: [Program.new("_sid" => "1", "platform" => "hackerone", "name" => "Acme")],
      total: 1, platforms: ["hackerone"], scope_types: ["web"], bounty_ceiling: 1000,
      page: 1, per_page: 30, has_next: false
    )
    stub_methods(Programs::Query, call: ->(_qp) { result }) do
      get programs_root_path
    end
    assert_response :success
    assert_select "h1", /Programs/
    assert_match "Acme", response.body
  end

  test "XHR next-page request returns the bare cards partial" do
    result = Programs::Query::Result.new(
      programs: [Program.new("_sid" => "1", "platform" => "hackerone", "name" => "Acme")],
      total: 1, platforms: ["hackerone"], scope_types: ["web"], bounty_ceiling: 1000,
      page: 1, per_page: 30, has_next: false
    )
    stub_methods(Programs::Query, call: ->(_qp) { result }) do
      get programs_root_path, headers: { "X-Requested-With" => "XMLHttpRequest" }
    end
    assert_response :success
    assert_match "Acme", response.body
    assert_no_match(/<h1/, response.body)
  end
end
