module Cves
  # Recurring job (Solid Queue) that mirrors OSV.dev into the `cves` collection.
  # Scheduled in config/recurring.yml. A full run re-pulls every ecosystem dump
  # and upserts; new records get a fresh first_seen_at, changed ones are updated.
  class SyncJob < ApplicationJob
    queue_as :background

    def perform
      Cves::Sync.new.run
    end
  end
end
