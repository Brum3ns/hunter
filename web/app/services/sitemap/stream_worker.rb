module Sitemap
  # Tails one collection's MongoDB change stream and applies events to the
  # Postgres projection via Sitemap::Applier, persisting the resume token after
  # each event so it resumes after a restart. `source` is nil for the alive
  # (target) collection, or "crawl" for the endpoint collection.
  # Reconciliation remains the backstop for anything missed here.
  class StreamWorker
    UPSERT_OPS = %w[insert update replace].freeze
    # After this many consecutive stream-open/consume failures, assume the
    # persisted resume token has fallen outside the oplog window and is no
    # longer resumable; clear it so the next attempt restarts from "now"
    # instead of retrying the same dead token forever.
    MAX_RESUME_FAILURES = 3

    def initialize(collection, source:)
      @collection = collection
      @source = source
      @failure_count = 0
    end

    def run
      loop do
        stream = Sitemap::MongoSource.change_stream(@collection, resume_after: MongoStreamCursor.token_for(@collection))
        stream.each { |event| apply_event(event) }
      rescue Mongo::Error => e
        Rails.logger.warn("Sitemap::StreamWorker(#{@collection}) reconnecting (#{e.class}: #{e.message})")
        record_stream_failure
        sleep 1
      rescue StandardError => e
        Rails.logger.warn("Sitemap::StreamWorker(#{@collection}) recovering from unexpected error (#{e.class}: #{e.message})")
        sleep 1
      end
    end

    def apply_event(event)
      op = event["operationType"]
      now = Time.current
      if UPSERT_OPS.include?(op)
        apply_upsert(event["fullDocument"], now)
      elsif op == "delete"
        apply_delete(event.dig("documentKey", "_id"), now)
      end
      save_token(event["_id"])
      @failure_count = 0
    end

    private

    # Increments the consecutive-failure counter; once it reaches
    # MAX_RESUME_FAILURES, clears the persisted resume token (so the next
    # #run iteration opens a fresh, unbounded change stream) and resets the
    # counter. Returns whether it cleared the token.
    def record_stream_failure
      @failure_count += 1
      return false unless @failure_count >= MAX_RESUME_FAILURES

      MongoStreamCursor.save_token(@collection, {})
      Rails.logger.warn("Sitemap::StreamWorker(#{@collection}) resume token invalid after #{@failure_count} failures; restarting from now")
      @failure_count = 0
      true
    end

    def apply_upsert(doc, now)
      return unless doc
      if @source.nil?
        attrs = Sitemap::TargetNormalizer.call(doc) or return
        target = Sitemap::Applier.upsert_target(attrs, now: now)
        Sitemap::Applier.attach_orphans_for(target, now: now)
      else
        attrs = Sitemap::EndpointNormalizer.call(doc) or return
        Sitemap::Applier.upsert_endpoint(attrs, now: now)
      end
    end

    def apply_delete(mongo_id, now)
      return if mongo_id.blank?
      if @source.nil?
        target = Sitemap::Target.find_by(alive_mongo_id: mongo_id.to_s)
        target&.tombstone!(now)
      else
        Sitemap::Applier.tombstone_endpoint_by_mongo_id(mongo_id.to_s, now: now)
      end
    end

    def save_token(token)
      MongoStreamCursor.save_token(@collection, token) if token.present?
    end
  end
end
