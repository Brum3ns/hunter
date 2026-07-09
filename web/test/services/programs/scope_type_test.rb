require "test_helper"

class Programs::ScopeTypeTest < ActiveSupport::TestCase
  test "canonical_for folds upstream tokens into buckets" do
    assert_equal :android, Programs::ScopeType.canonical_for("GOOGLE_PLAY_APP_ID")
    assert_equal :web,     Programs::ScopeType.canonical_for("URL")
    assert_equal :other,   Programs::ScopeType.canonical_for("mystery")
  end

  test "expand returns raw tokens for canonical keys" do
    assert_includes Programs::ScopeType.expand([:android]), "GOOGLE_PLAY_APP_ID"
  end
end
