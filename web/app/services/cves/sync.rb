module Cves
  # Mirrors OSV.dev into the `cves` collection: for each ecosystem, stream
  # records, keep only CVE-bearing ones (normalizer returns nil otherwise), and
  # upsert by CVE id. One bad ecosystem dump is logged and skipped so it can't
  # fail the whole run.
  class Sync
    def initialize(client: Cves::OsvClient.new, source: Cves::MongoSource)
      @client = client
      @source = source
    end

    def run(ecosystems: nil)
      stats = { ecosystems: 0, upserted: 0, skipped: 0, failed_ecosystems: 0 }
      (ecosystems || @client.ecosystems).each do |eco|
        stats[:ecosystems] += 1
        sync_ecosystem(eco, stats)
      end
      Rails.logger.info("Cves::Sync complete: #{stats.inspect}")
      stats
    end

    private

    def sync_ecosystem(eco, stats)
      @client.each_record(eco) do |raw|
        doc = Cves::Normalizer.call(raw)
        if doc.nil?
          stats[:skipped] += 1
          next
        end
        @source.upsert(doc)
        stats[:upserted] += 1
      end
    rescue => e
      stats[:failed_ecosystems] += 1
      Rails.logger.warn("Cves::Sync ecosystem #{eco} failed (#{e.class}: #{e.message})")
    end
  end
end
