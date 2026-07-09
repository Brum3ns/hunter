module Programs
  # Source is the read side of the program catalog. Programs are populated by
  # the Scope Go CLI (`scope -odb`) which upserts each program into MongoDB
  # keyed on `_sid`. We do not persist programs in Postgres — Mongo is the
  # source of truth and the web app reads from it on each request.
  class Source
    def self.all                   = new.all
    def self.find(sid)             = new.find(sid)
    def self.changes_since(time)   = new.changes_since(time)
    def self.latest_update         = new.latest_update

    def all
      mongo_docs.map { |hash| Program.new(hash) }
    end

    def find(sid)
      hash = mongo_doc(sid)
      hash && Program.new(hash)
    end

    # Programs whose `updated_at` strictly exceeds the given time. Used by the
    # API to surface change deltas to clients polling for updates.
    def changes_since(time)
      return [] unless time
      Programs::MongoSource.collection
        .find(updated_at: { "$gt" => time })
        .sort(updated_at: 1)
        .map { |doc| Program.new(stringify(doc)) }
    rescue Mongo::Error => e
      Rails.logger.warn("mongo: changes_since failed (#{e.message})")
      []
    end

    # Timestamp of the most recently updated program, or nil when the
    # collection is empty / unreachable. Cheap cursor the web layer can use
    # as the `since` value on its next poll.
    def latest_update
      doc = Programs::MongoSource.collection.find.sort(updated_at: -1).limit(1).first
      doc && doc["updated_at"]
    rescue Mongo::Error
      nil
    end

    private

    def mongo_docs
      Programs::MongoSource.collection.find.map { |doc| stringify(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("mongo: read failed (#{e.message})")
      []
    end

    def mongo_doc(sid)
      doc = Programs::MongoSource.collection.find(_sid: sid).limit(1).first
      doc && stringify(doc)
    rescue Mongo::Error
      nil
    end

    # BSON docs come back with symbol-like keys in some driver versions. The
    # Program PORO indexes by string keys, so normalize here once.
    def stringify(doc)
      doc.is_a?(Hash) ? doc.transform_keys(&:to_s) : doc
    end
  end
end
