require "test_helper"

class Targets::IndexTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Targets::MongoSource

  def stub_index(docs:, count:)
    stub_methods(Source, all: ->(*) { docs }, count: ->(*) { count }) { yield }
  end

  test "redirects an unauthenticated visitor to sign in" do
    get targets_path
    assert_redirected_to new_session_path
  end

  test "renders the table with default columns and marks the nav active" do
    sign_in_as(@user)
    doc = {
      "id" => "1",
      "target" => { "host" => "grafana.example.com", "ip" => "1.2.3.4", "port" => "443" },
      "http" => { "status_code" => 200, "title" => "Home" },
      "tech" => ["PHP"]
    }
    stub_index(docs: [doc], count: 1) do
      get targets_path
      assert_response :success
      assert_select "[data-controller~=targets-columns]"
      assert_select "[data-col=host]"
      assert_select "[data-col=technologies]"
      assert_select "a[href=?][aria-current=page]", targets_path
      assert_select "nav[aria-label='Target sections']" do
        assert_select "a[href=?][aria-current=page]", targets_path, text: "Target"
        assert_select "a[href=?]:not([aria-current])", targets_sitemap_path, text: "Sitemap"
      end
      assert_select "span[title=PHP] svg"
      assert_select "[data-targets-columns-target=header]"
      assert_select "[data-action~=?]", "mousedown->targets-columns#startResize"
      assert_select "input[data-col=url][data-action~=?]", "targets-columns#toggle"
      # Rows open the docked panel via rowlink into the target_panel frame.
      assert_select "[data-controller~=rowlink][data-rowlink-frame-value=target_panel]"
      assert_select "[data-rowlink-url-value=?]", target_path("1")
      assert_select "turbo-frame#target_panel"
    end
  end

  test "wires infinite scroll with a next-page URL when more pages exist" do
    sign_in_as(@user)
    doc = { "id" => "1", "target" => { "host" => "a.example.com" }, "http" => { "status_code" => 200 } }
    stub_index(docs: [doc], count: 120) do
      get targets_path
      assert_response :success
      assert_select "[data-controller~=targets-infinite]"
      assert_select "[data-targets-infinite-url-value=?]", targets_path(page: 2)
      assert_select "[data-targets-infinite-target=sentinel]"
    end
  end

  test "an XHR request returns just the rows fragment with a next-url marker" do
    sign_in_as(@user)
    doc = { "id" => "1", "target" => { "host" => "a.example.com" }, "http" => { "status_code" => 200 } }
    stub_methods(Source, all: ->(*) { [doc] }, count: ->(*) { 120 }) do
      get targets_path(page: 2), headers: { "X-Requested-With" => "XMLHttpRequest" }
      assert_response :success
      assert_select "[data-target-row]"
      assert_select "[data-next-url]"
      # A fragment, not the full page (no search form / toolbar chrome).
      assert_select "form", false
      assert_select "[data-controller~=targets-columns]", false
    end
  end

  test "does not paginate past the last page" do
    sign_in_as(@user)
    doc = { "id" => "1", "target" => { "host" => "a.example.com" }, "http" => { "status_code" => 200 } }
    stub_index(docs: [doc], count: 1) do
      get targets_path
      assert_select "[data-targets-infinite-url-value=?]", ""
    end
  end

  test "forwards q, sort and dir to the source" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) { captured = { search:, sort:, dir: }; [] }
    stub_methods(Source, all: capture, count: ->(*) { 0 }) do
      get targets_path, params: { q: "nginx", sort: "host", dir: "asc" }
    end
    assert_equal "nginx", captured[:search]
    assert_equal "host", captured[:sort]
    assert_equal "asc", captured[:dir]
  end

  test "splits a dork query into free text and an expression" do
    sign_in_as(@user)
    captured = nil
    capture = ->(filters:, search:, expression:, sort:, dir:, page:, limit:) { captured = { search:, expression: }; [] }
    stub_methods(Source, all: capture, count: ->(*) { 0 }) do
      get targets_path, params: { q: "nginx host:example.com" }
    end
    assert_equal "nginx", captured[:search]
    assert_equal Targets::DorkExpression::Term.new(key: "host", op: nil, value: "example.com"), captured[:expression]
  end
end
