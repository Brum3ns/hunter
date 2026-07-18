require "test_helper"

class Sitemap::TargetTest < ActiveSupport::TestCase
  def build!(origin: "https://ex.com:443", **over)
    Sitemap::Target.create!({ origin: origin, scheme: "https", host: "ex.com",
      port: 443, first_seen_at: Time.current, last_seen_at: Time.current }.merge(over))
  end

  test "active and tombstoned scopes" do
    live = build!
    dead = build!(origin: "http://ex.com:80", scheme: "http", port: 80, removed_at: Time.current)
    assert_includes Sitemap::Target.active, live
    assert_includes Sitemap::Target.tombstoned, dead
    refute_includes Sitemap::Target.active, dead
  end

  test "tombstone! sets removed_at" do
    t = build!
    t.tombstone!(Time.current)
    assert t.removed_at.present?
  end
end
