require "test_helper"

class Sitemap::TargetNormalizerTest < ActiveSupport::TestCase
  test "maps an alive doc to target attrs" do
    doc = { "_id" => "aid1", "target" => { "scheme" => "https", "host" => "Ex.com", "port" => 443 },
            "metadata" => { "program" => "acme" } }
    r = Sitemap::TargetNormalizer.call(doc)
    assert_equal "https://ex.com:443", r[:origin]
    assert_equal "acme", r[:program]
    assert_equal "aid1", r[:alive_mongo_id]
    assert_equal 443, r[:port]
  end

  test "returns nil when origin cannot be built" do
    assert_nil Sitemap::TargetNormalizer.call({ "target" => { "scheme" => "https" } })
  end
end
