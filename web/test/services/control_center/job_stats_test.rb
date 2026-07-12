require "test_helper"

class ControlCenter::JobStatsTest < ActiveSupport::TestCase
  def job(**over)
    ControlCenter::Job.create!({ template_name: "t", status: "succeeded", queue_name: "test", target_count: 1 }.merge(over))
  end

  test "totals, success rate, targets, and distinct templates" do
    job(template_name: "a", status: "succeeded", target_count: 2)
    job(template_name: "a", status: "failed", target_count: 3)
    job(template_name: "b", status: "pending", target_count: 5)
    t = ControlCenter::JobStats.dashboard[:totals]
    assert_equal 3, t[:jobs]
    assert_equal 1, t[:succeeded]
    assert_equal 1, t[:failed]
    assert_equal 1, t[:pending]
    assert_equal 50, t[:success_rate]
    assert_equal 10, t[:targets]
    assert_equal 2, t[:templates_used]
  end

  test "top templates ranked by count" do
    3.times { job(template_name: "hot") }
    job(template_name: "cold")
    top = ControlCenter::JobStats.dashboard[:top_templates]
    assert_equal({ label: "hot", count: 3 }, top.first)
  end

  test "daily series is zero-filled to 30 days ending today" do
    job
    daily = ControlCenter::JobStats.dashboard[:daily]
    assert_equal 30, daily.length
    assert_equal 1, daily.sum { |d| d[:count] }
    assert_equal Date.current.iso8601, daily.last[:date]
  end

  test "by_status always lists the three statuses in order" do
    assert_equal %w[succeeded failed pending],
                 ControlCenter::JobStats.dashboard[:by_status].map { |r| r[:label] }
  end
end
