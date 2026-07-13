require "test_helper"

class Cves::LanguagesTest < ActiveSupport::TestCase
  test "maps known ecosystems and dedups" do
    assert_equal ["JavaScript"], Cves::Languages.call(["npm"])
    assert_equal ["Python"], Cves::Languages.call(["PyPI"])
    assert_equal ["Java"], Cves::Languages.call(["Maven"])
  end

  test "drops unknown ecosystems and is case-insensitive" do
    assert_equal ["JavaScript"], Cves::Languages.call(["NPM", "SomethingElse"])
    assert_equal [], Cves::Languages.call(["Linux"])
  end
end
