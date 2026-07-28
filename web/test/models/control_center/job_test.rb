require "test_helper"

class ControlCenter::JobTest < ActiveSupport::TestCase
  test "valid job saves" do
    job = ControlCenter::Job.new(template_name: "probe", queue_name: "test", target_count: 3, status: "pending")
    assert job.valid?
  end

  test "status must be known" do
    job = ControlCenter::Job.new(template_name: "probe", status: "weird")
    assert_not job.valid?
  end

  test "queued and running are valid statuses" do
    %w[queued running succeeded failed].each do |s|
      j = ControlCenter::Job.new(template_name: "t", status: s)
      assert j.valid?, "#{s} should be a valid status"
    end
  end

  test "selections and manual_targets default to empty arrays" do
    j = ControlCenter::Job.create!(template_name: "t", status: "queued", queue_name: "test", target_count: 0)
    assert_equal [], j.selections
    assert_equal [], j.manual_targets
    assert_equal 0, j.target_chunk
    assert_equal 0, j.job_delay_ms
  end

  test "idempotency_key is unique per author" do
    ControlCenter::Job.create!(template_name: "t", status: "queued", queue_name: "test", target_count: 0, created_by: "u", idempotency_key: "k1")
    dup = ControlCenter::Job.new(template_name: "t", status: "queued", queue_name: "test", target_count: 0, created_by: "u", idempotency_key: "k1")
    assert_raises(ActiveRecord::RecordNotUnique) { dup.save!(validate: false) }
  end
end
