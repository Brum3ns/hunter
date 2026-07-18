module Sitemap
  # Full-pass Mongo -> Postgres reconciliation: the Phase 1 sync and the
  # permanent backstop for the Phase 2 stream worker. Idempotent and
  # self-healing; safe to run repeatedly. Deletes are detected by an epoch:
  # rows not refreshed this run (last_seen_at < run_at) are tombstoned.
  class Reconciliation
    def run
      run_at = Time.current
      stats = { targets_upserted: 0, endpoints_upserted: 0, targets_tombstoned: 0, endpoints_tombstoned: 0 }

      alive_ok = Sitemap::MongoSource.each_alive do |doc|
        attrs = Sitemap::TargetNormalizer.call(doc) or next
        Sitemap::Applier.upsert_target(attrs, now: run_at)
        stats[:targets_upserted] += 1
      end

      source_ok = {}
      %w[katana wayback].each do |source|
        source_ok[source] = Sitemap::MongoSource.public_send("each_#{source}") do |doc|
          attrs = Sitemap::EndpointNormalizer.call(doc, source: source) or next
          Sitemap::Applier.upsert_endpoint(attrs, now: run_at)
          stats[:endpoints_upserted] += 1
        end
      end
      katana_ok = source_ok["katana"]
      wayback_ok = source_ok["wayback"]

      if alive_ok
        stats[:targets_tombstoned] =
          Sitemap::Target.active.where(last_seen_at: ...run_at).update_all(removed_at: run_at)
      else
        Rails.logger.warn("Sitemap::Reconciliation skipping target tombstoning: alive scan incomplete")
      end

      if katana_ok && wayback_ok
        stats[:endpoints_tombstoned] =
          Sitemap::Endpoint.active.where(last_seen_at: ...run_at).update_all(removed_at: run_at)
      else
        Rails.logger.warn("Sitemap::Reconciliation skipping endpoint tombstoning: katana_ok=#{katana_ok} wayback_ok=#{wayback_ok}")
      end

      Sitemap::Target.active.find_each { |t| Sitemap::Applier.attach_orphans_for(t, now: run_at) }

      Rails.logger.info("Sitemap::Reconciliation complete: #{stats.inspect}")
      stats
    end
  end
end
