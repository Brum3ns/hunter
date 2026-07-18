require "test_helper"

class Sitemap::SyncJobTest < ActiveJob::TestCase
  test "perform runs a full Sitemap::Reconciliation" do
    ran = false
    fake = Object.new
    fake.define_singleton_method(:run) { |*| ran = true; { targets_upserted: 0 } }
    stub_methods(Sitemap::Reconciliation, new: fake) do
      Sitemap::SyncJob.new.perform
    end
    assert ran, "expected the job to invoke Sitemap::Reconciliation#run"
  end
end
