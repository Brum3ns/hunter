require "test_helper"

class Cves::SyncJobTest < ActiveJob::TestCase
  test "perform runs a full Cves::Sync" do
    ran = false
    fake = Object.new
    fake.define_singleton_method(:run) { |*| ran = true; { upserted: 0 } }
    stub_methods(Cves::Sync, new: fake) do
      Cves::SyncJob.new.perform
    end
    assert ran, "expected the job to invoke Cves::Sync#run"
  end
end
