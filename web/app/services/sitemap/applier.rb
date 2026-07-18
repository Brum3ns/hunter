module Sitemap
  # Per-document primitives shared by the reconciliation job (Phase 1) and the
  # change-stream worker (Phase 2). All writes go through here so both paths
  # apply identical matching, merge and tombstone rules.
  module Applier
    module_function

    def upsert_target(attrs, now:)
      t = Sitemap::Target.find_or_initialize_by(origin: attrs[:origin])
      t.first_seen_at ||= now
      t.assign_attributes(
        scheme: attrs[:scheme], host: attrs[:host], port: attrs[:port],
        program: attrs[:program], alive_mongo_id: attrs[:alive_mongo_id],
        last_seen_at: now, removed_at: nil
      )
      t.save!
      t
    end

    def upsert_endpoint(attrs, now:)
      digest = Sitemap::Origin.digest(attrs[:url], attrs[:method])
      target = Sitemap::Target.active.find_by(origin: attrs[:origin])
      ep = find_endpoint(target, attrs[:origin], digest) ||
           Sitemap::Endpoint.new(origin: attrs[:origin], url: attrs[:url], path: attrs[:path],
                                 method: attrs[:method], url_digest: digest, first_seen_at: now)
      ep.target_id = target&.id
      apply_source(ep, attrs)
      ep.status_code    = attrs[:status_code]    if attrs[:status_code].present?
      ep.content_length = attrs[:content_length] if attrs[:content_length].present?
      ep.content_type   = attrs[:content_type]   if attrs[:content_type].present?
      ep.last_seen_at = now
      ep.removed_at = nil
      ep.save!
      ep
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

    def tombstone_endpoint_by_source(source, mongo_id, now:)
      col = source == "katana" ? :katana_mongo_id : :wayback_mongo_id
      Sitemap::Endpoint.where(col => mongo_id).find_each do |ep|
        ep.public_send("#{col}=", nil)
        derived = Sitemap::Endpoint.derive_source(ep.katana_mongo_id, ep.wayback_mongo_id)
        # `source` is NOT NULL at the DB level; once no provenance remains we
        # leave the last-known source in place and rely on removed_at as the
        # tombstone marker instead of nulling this column out.
        ep.source = derived if derived
        ep.removed_at = now if derived.nil?
        ep.save!
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

    def apply_source(ep, attrs)
      if attrs[:source] == "katana"
        ep.katana_mongo_id = attrs[:source_mongo_id]
      else
        ep.wayback_mongo_id = attrs[:source_mongo_id]
      end
      ep.source = Sitemap::Endpoint.derive_source(ep.katana_mongo_id, ep.wayback_mongo_id)
    end
    private_class_method :apply_source

    def merge_into(existing, orphan, now)
      existing.katana_mongo_id  ||= orphan.katana_mongo_id
      existing.wayback_mongo_id ||= orphan.wayback_mongo_id
      existing.source = Sitemap::Endpoint.derive_source(existing.katana_mongo_id, existing.wayback_mongo_id)
      existing.last_seen_at = [existing.last_seen_at, orphan.last_seen_at, now].compact.max
      existing.removed_at = nil
      existing.save!
    end
    private_class_method :merge_into
  end
end
