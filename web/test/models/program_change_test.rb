require "test_helper"

class ProgramChangeTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "recent orders newest-detected first" do
    old = ProgramChange.create!(user: @user, kind: "program_added", detected_at: 2.days.ago)
    new = ProgramChange.create!(user: @user, kind: "bounty_changed", detected_at: 1.hour.ago)
    assert_equal [new.id, old.id], ProgramChange.recent.pluck(:id)
  end

  test "as_feed_json exposes the feed fields" do
    change = ProgramChange.create!(user: @user, platform: "bugcrowd", program_sid: "acme",
                                   program_name: "Acme", kind: "bounty_changed",
                                   old_value: { "bounty_max" => 100 }, new_value: { "bounty_max" => 500 },
                                   detected_at: Time.current)
    json = change.as_feed_json
    assert_equal "acme", json[:program_sid]
    assert_equal({ "bounty_max" => 500 }, json[:new_value])
    assert json[:detected_at].is_a?(String)
  end
end
