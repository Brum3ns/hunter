require "test_helper"

class Cves::TaggerTest < ActiveSupport::TestCase
  test "tags a wordpress package as cms" do
    tags = Cves::Tagger.call(
      ecosystems: ["Packagist"],
      affected: [{ "package" => "johndoe/wordpress-seo" }],
      vendors: ["johndoe"]
    )
    assert_includes tags, "cms"
  end

  test "returns empty and unique when no rule matches" do
    assert_equal [], Cves::Tagger.call(ecosystems: ["npm"], affected: [{ "package" => "lodash" }], vendors: [])
  end
end
