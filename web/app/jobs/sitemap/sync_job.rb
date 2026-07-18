module Sitemap
  # Recurring job (Solid Queue) that runs the full-pass Mongo -> Postgres
  # reconciliation. Scheduled in config/recurring.yml. Mirrors Cves::SyncJob.
  class SyncJob < ApplicationJob
    queue_as :background

    def perform
      Sitemap::Reconciliation.new.run
    end
  end
end
