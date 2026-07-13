require "test_helper"

class Cves::VendorsTest < ActiveSupport::TestCase
  def call(affected) = Cves::Vendors.call(affected)

  test "extracts the purl namespace as vendor" do
    assert_equal ["acme"], call([{ "purl" => "pkg:composer/acme/widget" }])
  end

  test "decodes and strips an npm scope" do
    assert_equal ["scope"], call([{ "purl" => "pkg:npm/%40scope/name" }])
  end

  test "uses the segment before the name for multi-segment namespaces" do
    assert_equal ["org"], call([{ "purl" => "pkg:golang/github.com/org/repo" }])
  end

  test "falls back to an npm-scoped package name when purl is absent" do
    assert_equal ["scope"], call([{ "package" => "@scope/name" }])
  end

  test "returns empty when nothing is derivable and dedups across entries" do
    assert_equal [], call([{ "package" => "lodash" }])
    assert_equal ["acme"], call([
      { "purl" => "pkg:composer/acme/a" }, { "purl" => "pkg:composer/acme/b" }
    ])
  end
end
