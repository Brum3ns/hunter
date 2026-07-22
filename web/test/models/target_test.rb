require "test_helper"

class TargetTest < ActiveSupport::TestCase
  DOC = {
    "id" => "abc",
    "metadata" => { "program" => "acme", "date" => "2026-02-01T00:00:00Z" },
    "target" => { "url" => "https://a.example.com", "host" => "a.example.com",
                  "ip" => "1.2.3.4", "port" => "443", "scheme" => "https",
                  "path" => "/", "method" => "GET" },
    "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx",
                "content_type" => "text/html", "content_length" => 12,
                "words" => 3, "lines" => 1, "response_time" => "120ms" },
    "tech" => ["PHP", "Nginx"],
    "fingerprint" => { "page_type" => "other" }
  }.freeze

  test "maps nested document fields to flat accessors" do
    t = Target.new(DOC)
    assert_equal "abc", t.id
    assert_equal "a.example.com", t.host
    assert_equal "443", t.port
    assert_equal "GET", t.verb
    assert_equal 200, t.status_code
    assert_equal "nginx", t.webserver
    assert_equal %w[PHP Nginx], t.tech
    assert_equal "acme", t.program
    assert_equal "other", t.page_type
    assert_equal "2026-02-01T00:00:00Z", t.seen_at
  end

  test "tech is always an array even when missing" do
    assert_equal [], Target.new({}).tech
  end

  test "status_family buckets the status code" do
    assert_equal "2xx", Target.new("http" => { "status_code" => 200 }).status_family
    assert_equal "3xx", Target.new("http" => { "status_code" => 301 }).status_family
    assert_equal "4xx", Target.new("http" => { "status_code" => 404 }).status_family
    assert_equal "5xx", Target.new("http" => { "status_code" => 500 }).status_family
    assert_equal "other", Target.new({}).status_family
  end

  test "as_json returns the underlying attributes" do
    assert_equal "acme", Target.new(DOC).as_json["metadata"]["program"]
  end

  test "exposes the detail-panel fields (headers, csp, fingerprint, metadata)" do
    doc = DOC.merge(
      "headers" => { "server" => "nginx" },
      "csp" => { "fqdn" => ["a.example.com"], "domains" => ["example.com"] },
      "fingerprint" => { "page_type" => "other", "phash" => 42 },
      "metadata" => DOC["metadata"].merge("tool" => "httpx", "scan_id" => "s1", "failed" => false)
    )
    t = Target.new(doc)
    assert_equal({ "server" => "nginx" }, t.headers)
    assert_equal ["example.com"], t.csp["domains"]
    assert_equal 42, t.phash
    assert_equal "httpx", t.tool
    assert_equal "s1", t.scan_id
    assert_equal false, t.failed
  end

  test "input reads target.input" do
    assert_equal "example.com", Target.new("target" => { "input" => "example.com" }).input
  end

  test "detail fields default to empty containers when absent" do
    t = Target.new({})
    assert_equal({}, t.headers)
    assert_equal({}, t.csp)
    assert_equal({}, t.fingerprint)
    assert_nil t.phash
  end
end
