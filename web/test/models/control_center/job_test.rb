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
end
