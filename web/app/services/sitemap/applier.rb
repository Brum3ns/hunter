module Sitemap
  # Per-document primitives shared by the reconciliation job (Phase 1) and the
  # change-stream worker (Phase 2). All writes go through here so both paths
  # apply identical matching, merge and tombstone rules.
  module Applier
    module_function

    def upsert_target(attrs, now:)
      assign = lambda do |t|
        t.first_seen_at ||= now
        t.assign_attributes(
          scheme: attrs[:scheme], host: attrs[:host], port: attrs[:port],
          program: attrs[:program], alive_mongo_id: attrs[:alive_mongo_id],
          last_seen_at: now, removed_at: nil
        )
        t
      end
      t = assign.call(Sitemap::Target.find_or_initialize_by(origin: attrs[:origin]))
      save_with_unique_retry(t) { assign.call(Sitemap::Target.find_by!(origin: attrs[:origin])) }
    end

    def upsert_endpoint(attrs, now:)
      digest = Sitemap::Origin.digest(attrs[:url], attrs[:method])
      target = Sitemap::Target.active.find_by(origin: attrs[:origin])
      assign = lambda do |ep|
        ep.target_id = target&.id
        ep.crawl_mongo_id = attrs[:crawl_mongo_id] if attrs[:crawl_mongo_id].present?
        ep.status_code    = attrs[:status_code]    if attrs[:status_code].present?
        ep.content_length = attrs[:content_length] if attrs[:content_length].present?
        ep.content_type   = attrs[:content_type]   if attrs[:content_type].present?
        ep.last_seen_at = now
        ep.removed_at = nil
        ep
      end
      ep = assign.call(
        find_endpoint(target, attrs[:origin], digest) ||
        Sitemap::Endpoint.new(origin: attrs[:origin], url: attrs[:url], path: attrs[:path],
                              method: attrs[:method], url_digest: digest, first_seen_at: now)
      )
      save_with_unique_retry(ep) do
        found = find_endpoint(target, attrs[:origin], digest) ||
                raise(ActiveRecord::RecordNotFound, "endpoint disappeared mid-retry for origin=#{attrs[:origin]}")
        assign.call(found)
      end
    end

    def attach_orphans_for(target, now:)
      Sitemap::Endpoint.unmatched.where(origin: target.origin).find_each do |orphan|
        existing = Sitemap::Endpoint.find_by(target_id: target.id, url_digest: orphan.url_digest)
        if existing
          merge_into(existing, orphan, now)
          orphan.destroy!
        else
          orphan.update!(target_id: target.id)
        end
      end
    end

    # A change-stream delete of a crawl doc tombstones the endpoint(s) that
    # carried its id. Reconciliation's epoch pass remains the authority if the
    # same URL is still present via another (yet-unseen) crawl doc.
    def tombstone_endpoint_by_mongo_id(mongo_id, now:)
      Sitemap::Endpoint.where(crawl_mongo_id: mongo_id).find_each do |ep|
        ep.update!(removed_at: now)
      end
    end

    # --- helpers ---

    def find_endpoint(target, origin, digest)
      if target
        Sitemap::Endpoint.find_by(target_id: target.id, url_digest: digest)
      else
        Sitemap::Endpoint.unmatched.find_by(origin: origin, url_digest: digest)
      end
    end
    private_class_method :find_endpoint

    # Saves `record`; if a concurrent writer (reconciliation vs. the stream
    # worker) won the race and inserted the same natural-key row first, this
    # rescues the unique violation exactly once, re-finds the now-existing
    # row via the given block (which re-applies the same field updates), and
    # saves that instead. A second violation is a real bug and propagates.
    def save_with_unique_retry(record)
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      retried = yield
      retried.save!
      retried
    end
    private_class_method :save_with_unique_retry

    def merge_into(existing, orphan, now)
      existing.crawl_mongo_id ||= orphan.crawl_mongo_id
      existing.last_seen_at = [ existing.last_seen_at, orphan.last_seen_at, now ].compact.max
      existing.removed_at = nil
      existing.save!
    end
    private_class_method :merge_into
  end
end
