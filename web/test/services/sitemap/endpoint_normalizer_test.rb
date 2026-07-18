require "test_helper"

class Sitemap::EndpointNormalizerTest < ActiveSupport::TestCase
  test "maps a katana doc" do
    doc = { "_id" => "kid1",
            "request" => { "endpoint" => "https://Ex.com/a?x=1", "method" => "post" },
            "response" => { "status_code" => 200, "content_length" => 12,
                            "headers" => { "Content-Type" => "text/html" } } }
    r = Sitemap::EndpointNormalizer.call(doc, source: "katana")
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "https://ex.com:443/a?x=1", r[:url]
    assert_equal "/a", r[:path]
    assert_equal "POST", r[:method]
    assert_equal 200, r[:status_code]
    assert_equal "text/html", r[:content_type]
    assert_equal "kid1", r[:source_mongo_id]
    assert_equal "katana", r[:source]
  end

  test "maps a wayback doc with defaults" do
    doc = { "_id" => "wid1", "url" => "http://ex.com/old" }
    r = Sitemap::EndpointNormalizer.call(doc, source: "wayback")
    assert_equal "http://ex.com:80", r[:origin]
    assert_equal "GET", r[:method]
    assert_nil r[:status_code]
    assert_equal "wid1", r[:source_mongo_id]
  end

  test "returns nil on an unparseable url" do
    assert_nil Sitemap::EndpointNormalizer.call({ "url" => "javascript:void(0)" }, source: "wayback")
    assert_nil Sitemap::EndpointNormalizer.call({ "request" => {} }, source: "katana")
  end
end
