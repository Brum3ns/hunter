require "test_helper"
require "rake"

class ControlCenterAnsibleRakeTest < ActiveSupport::TestCase
  test "control_center:ansible:reap task is defined" do
    Hunter::Application.load_tasks unless Rake::Task.task_defined?("control_center:ansible:reap")

    assert Rake::Task.task_defined?("control_center:ansible:reap")
  end
end
