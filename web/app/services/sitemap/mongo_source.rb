module Sitemap
  # Read-only streaming access to the source collections. Reads swallow
  # Mongo::Error (house rule); change_stream lets errors propagate so the worker
  # can back off and resume.
  module MongoSource
    module_function

    ALIVE = ENV.fetch("MONGO_ALIVE_COLLECTION", "alive")
    CRAWL = ENV.fetch("MONGO_CRAWL_COLLECTION", "crawl")

    def each_alive(&blk) = each(ALIVE, &blk)
    def each_crawl(&blk) = each(CRAWL, &blk)

    # Returns true when the scan completed, false when a Mongo::Error was
    # caught partway through (or before yielding anything) — callers must not
    # treat a false return as "nothing exists".
    def each(collection_name)
      HunterMongo.collection(collection_name).find.each { |doc| yield doc }
      true
    rescue Mongo::Error => e
      Rails.logger.warn("Sitemap::MongoSource#each(#{collection_name}) failed (#{e.class}: #{e.message})")
      false
    end

    def change_stream(collection_name, resume_after: nil)
      opts = { full_document: "updateLookup" }
      opts[:resume_after] = resume_after if resume_after.present?
      HunterMongo.collection(collection_name).watch([], opts)
    end
  end
end
