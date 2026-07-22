require "test_helper"

class Targets::ShowTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  Source = Targets::MongoSource

  DOC = {
    "id" => "abc",
    "metadata" => { "program" => "acme", "tool" => "httpx", "date" => "2026-02-01T00:00:00Z" },
    "target" => { "url" => "https://a.example.com", "host" => "a.example.com", "ip" => "1.2.3.4", "port" => "443" },
    "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx" },
    "headers" => { "server" => "nginx", "content-type" => "text/html" },
    "csp" => { "domains" => ["example.com"] },
    "tech" => ["PHP", "Nginx"],
    "fingerprint" => { "page_type" => "other" }
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    get target_path("abc")
    assert_redirected_to new_session_path
  end

  test "renders the detail panel into the target_panel frame" do
    sign_in_as(@user)
    stub_methods(Source, find: DOC) do
      get target_path("abc")
      assert_response :success
      assert_select "turbo-frame#target_panel"
      assert_select "[data-controller~=side-panel]"
      assert_select "aside[data-side-panel-target=panel]"
      assert_select "button[data-action~=?]", "click->side-panel#close"
      assert_select "h2", text: "a.example.com"
      assert_select "a[href=?]", "https://a.example.com"
    end
  end

  test "returns 404 when the asset is missing" do
    sign_in_as(@user)
    stub_methods(Source, find: nil) do
      get target_path("missing")
      assert_response :not_found
    end
  end
end
