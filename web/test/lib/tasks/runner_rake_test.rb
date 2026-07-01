require "test_helper"
require "rake"

class RunnerRakeTest < ActiveSupport::TestCase
  setup do
    @rake = Rake::Application.new
    Rake.application = @rake
    Rake.load_rakefile(Rails.root.join("lib/tasks/runner.rake").to_s)
    Rake::Task.define_task(:environment)
  end

  test "runners:create mints a runner and prints the raw token once" do
    ENV["NAME"] = "curl-runner"
    ENV["KINDS"] = "curl"
    out, = capture_io { @rake["runners:create"].invoke }
    assert Runner.find_by(name: "curl-runner")
    assert_match(/token/i, out)
  ensure
    ENV.delete("NAME"); ENV.delete("KINDS")
  end

  test "runners:reap fails stale running jobs" do
    user = users(:one)
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v", requested_by: user, status: "running", started_at: 1.hour.ago)
    capture_io { @rake["runners:reap"].invoke }
    assert_equal "failed", job.reload.status
  end
end
