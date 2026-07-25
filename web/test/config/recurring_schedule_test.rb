require "test_helper"

# Guards the recurring-jobs config: the CVE sync must be scheduled in both
# development and production, and must reference a real job class. Regression
# guard for "CVEs never fetch in dev" — that was caused by the development
# block being absent, so nothing enqueued Cves::SyncJob.
class RecurringScheduleTest < ActiveSupport::TestCase
  CONFIG = YAML.load_file(Rails.root.join("config/recurring.yml")).freeze

  %w[development production].each do |env|
    test "#{env} schedules the CVE sync against Cves::SyncJob" do
      entry = CONFIG.dig(env, "cve_sync")
      assert entry, "expected a cve_sync recurring entry under #{env}"
      assert_equal "Cves::SyncJob", entry["class"]
      assert entry["schedule"].present?, "cve_sync needs a schedule"
    end
  end

  test "the scheduled class resolves to a real job" do
    assert_equal Cves::SyncJob, "Cves::SyncJob".constantize
  end

  %w[development production].each do |env|
    test "#{env} schedules Ansible stale-work reaping every minute" do
      entry = CONFIG.dig(env, "control_center_ansible_reaper")

      assert entry, "expected an Ansible reaper recurring entry under #{env}"
      assert_equal "ControlCenter::Ansible::RunReaper.call", entry["command"]
      assert_equal "every minute", entry["schedule"]
    end
  end
end
