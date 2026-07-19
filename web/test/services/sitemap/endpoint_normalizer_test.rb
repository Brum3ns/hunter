require "test_helper"

class Sitemap::EndpointNormalizerTest < ActiveSupport::TestCase
  test "maps a crawl doc (request.url + flat response fields)" do
    doc = { "_id" => "c1",
            "request" => { "url" => "https://Ex.com/a?x=1", "method" => "post" },
            "response" => { "status_code" => 200, "content_length" => 12, "content_type" => "text/html" },
            "metadata" => { "program" => "acme" } }
    r = Sitemap::EndpointNormalizer.call(doc)
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "https://ex.com:443/a?x=1", r[:url]
    assert_equal "/a", r[:path]
    assert_equal "POST", r[:method]
    assert_equal 200, r[:status_code]
    assert_equal 12, r[:content_length]
    assert_equal "text/html", r[:content_type]
    assert_equal "c1", r[:crawl_mongo_id]
  end

  test "defaults method to GET and tolerates a missing response" do
    doc = { "_id" => "c2", "request" => { "url" => "http://ex.com/old" } }
    r = Sitemap::EndpointNormalizer.call(doc)
    assert_equal "http://ex.com:80", r[:origin]
    assert_equal "GET", r[:method]
    assert_nil r[:status_code]
    assert_equal "c2", r[:crawl_mongo_id]
  end

  test "falls back to a top-level id when _id is absent" do
    r = Sitemap::EndpointNormalizer.call({ "id" => "c3", "request" => { "url" => "https://ex.com/z" } })
    assert_equal "c3", r[:crawl_mongo_id]
  end

  test "returns nil on an unparseable or missing url" do
    assert_nil Sitemap::EndpointNormalizer.call({ "request" => { "url" => "javascript:void(0)" } })
    assert_nil Sitemap::EndpointNormalizer.call({ "request" => {} })
  end
end
