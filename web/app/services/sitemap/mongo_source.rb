module Sitemap
  # Read-only streaming access to the source collections. Reads swallow
  # Mongo::Error (house rule); change_stream lets errors propagate so the worker
  # can back off and resume.
  module MongoSource
    module_function

    ALIVE   = ENV.fetch("MONGO_ALIVE_COLLECTION", "alive")
    KATANA  = ENV.fetch("MONGO_KATANA_COLLECTION", "katana")
    WAYBACK = ENV.fetch("MONGO_WAYBACK_COLLECTION", "wayback")

    def each_alive(&blk)   = each(ALIVE, &blk)
    def each_katana(&blk)  = each(KATANA, &blk)
    def each_wayback(&blk) = each(WAYBACK, &blk)

    def each(collection_name)
      HunterMongo.collection(collection_name).find.each { |doc| yield doc }
    rescue Mongo::Error => e
      Rails.logger.warn("Sitemap::MongoSource#each(#{collection_name}) failed (#{e.class}: #{e.message})")
      nil
    end

    def change_stream(collection_name, resume_after: nil)
      opts = { full_document: "updateLookup" }
      opts[:resume_after] = resume_after if resume_after.present?
      HunterMongo.collection(collection_name).watch([], opts)
    end
  end
end
