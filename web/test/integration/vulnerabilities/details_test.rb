require "test_helper"

class Vulnerabilities::DetailsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }
  Source = Vulnerabilities::MongoSource
  OID = "507f1f77bcf86cd799439011"

  DOC = {
    "id" => OID,
    "metadata" => { "program" => "acme", "tool" => "nuclei", "description" => "Header fuzz" },
    "report"   => { "status" => "triage", "submitted" => false, "status_updated_by" => "brumens" },
    "finding"  => { "name" => "Header Fuzzer", "severity" => "low", "type" => "http", "tags" => ["fuzz"] },
    "target"   => { "host" => "helpdesk.mirakl.net", "url" => "https://helpdesk.mirakl.net",
                    "ip" => "1.2.3.4", "port" => "443", "method" => "GET" },
    "poc"      => { "curl" => "curl https://example", "extracted" => ["foo"] },
    "request"  => { "request" => "GET / HTTP/1.1", "response" => "HTTP/1.1 200 OK" }
  }.freeze

  test "redirects an unauthenticated visitor to sign in" do
    get vulnerabilities_detail_path(OID)
    assert_redirected_to new_session_path
  end

  test "renders the detail drawer inside the vuln_panel turbo frame" do
    sign_in_as(@user)
    stub_methods(Source, find: DOC) do
      get vulnerabilities_detail_path(OID)
    end

    assert_response :success
    assert_select "turbo-frame#vuln_panel"
    assert_select "h2", text: "Header Fuzzer"
    assert_match "helpdesk.mirakl.net", response.body
    assert_match "curl https://example", response.body
  end

  test "returns 404 when the vulnerability is not found" do
    sign_in_as(@user)
    stub_methods(Source, find: nil) do
      get vulnerabilities_detail_path("missing")
    end
    assert_response :not_found
  end
end
