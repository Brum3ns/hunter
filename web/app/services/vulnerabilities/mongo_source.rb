module Vulnerabilities
  # Full CRUD against the MongoDB `vulnerabilities` collection (handle in
  # HunterMongo). Mirrors scope-ui's Scope::MongoSource, with two differences:
  # writes as well as reads, and ObjectId-addressed lookups.
  #
  # Reads never raise to the controller — a transient Mongo outage yields an
  # empty result, not a crash. Writes let Mongo::Error propagate so the
  # controller can map it to a 502.
  module MongoSource
    module_function

    # This module owns the `vulnerabilities` collection. Env override kept for
    # back-compat with the running docker-compose (MONGO_COLLECTION).
    COLLECTION = ENV.fetch("MONGO_COLLECTION", "vulnerabilities")

    # Indexes the vulnerabilities module filters/sorts by.
    INDEXES = [
      { key: { "metadata.program": 1 },  name: "metadata_program" },
      { key: { "finding.severity": 1 },  name: "finding_severity" },
      { key: { "report.status": 1 },     name: "report_status" },
      { key: { "metadata.tool": 1 },     name: "metadata_tool" },
      { key: { "finding.type": 1 },      name: "finding_type" },
      { key: { "metadata.date": -1 },    name: "metadata_date" }
    ].freeze

    # Public filter key -> nested Mongo field. Anything else is ignored.
    FILTER_KEYS = {
      "program"  => "metadata.program",
      "severity" => "finding.severity",
      "status"   => "report.status",
      "tool"     => "metadata.tool"
    }.freeze

    # Free-text search matches any of these fields (case-insensitive).
    SEARCH_FIELDS = %w[finding.name target.host].freeze

    def all(filters: {}, search: nil, page: 1, limit: 50)
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      skip = ([page.to_i, 1].max - 1) * limit
      docs = collection.find(build_filter(filters, search))
                       .sort("metadata.date" => -1)
                       .skip(skip)
                       .limit(limit)
                       .to_a
      docs.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {}, search: nil)
      collection.count_documents(build_filter(filters, search))
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end

    def find(id)
      oid = to_object_id(id)
      return nil unless oid
      doc = collection.find(_id: oid).first
      doc && normalize(doc)
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::MongoSource#find failed (#{e.class}: #{e.message})")
      nil
    end

    def create(attrs)
      collection.insert_one(strip_ids(attrs)).inserted_id.to_s
    end

    def update(id, attrs)
      oid = to_object_id(id)
      return nil unless oid
      result = collection.update_one({ _id: oid }, { "$set" => strip_ids(attrs) })
      return nil if result.matched_count.zero?
      find(id)
    end

    def delete(id)
      oid = to_object_id(id)
      return false unless oid
      collection.delete_one(_id: oid).deleted_count.positive?
    end

    # Sets the shared status plus attribution (who + when) on a vulnerability.
    # Validates the vocabulary here so a bad value never reaches Mongo. Reuses
    # `update` (ObjectId-addressed $set with dotted keys, so the rest of `report`
    # is preserved). Write failures propagate as Mongo::Error (-> 502).
    def update_status(id:, status:, user:)
      unless VulnerabilitiesHelper::STATUSES.include?(status.to_s)
        raise ArgumentError, "invalid status: #{status.inspect}"
      end
      update(id, {
        "report.status"            => status.to_s,
        "report.status_updated_by" => user.username,
        "report.status_updated_at" => Time.now.utc
      })
    end

    def collection
      HunterMongo.collection(COLLECTION)
    end

    # Bootstrap this module's indexes (idempotent, once per process). Callers
    # that build their own queries (e.g. Vulnerabilities::Query) invoke this so
    # the collection name + INDEXES stay owned in one place.
    def ensure_indexes!
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
    end

    def build_filter(filters, search = nil)
      base = filters.to_h.each_with_object({}) do |(key, value), mongo|
        next if value.blank?
        mongo_key = FILTER_KEYS[key.to_s]
        mongo[mongo_key] = value if mongo_key
      end
      if search.present?
        rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }
        base["$or"] = SEARCH_FIELDS.map { |field| { field => rx } }
      end
      base
    end
    private_class_method :build_filter

    # Mongo owns the identity; never let a client-supplied id/_id overwrite it.
    def strip_ids(attrs)
      attrs.to_h.reject { |k, _| %w[id _id].include?(k.to_s) }
    end
    private_class_method :strip_ids

    def to_object_id(id)
      BSON::ObjectId.from_string(id.to_s)
    rescue BSON::Error::InvalidObjectId
      nil
    end
    private_class_method :to_object_id

    # Stringify keys and surface Mongo's BSON _id as a plain string `id`.
    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      oid = hash.delete("_id")
      hash["id"] = oid.to_s if oid
      hash
    end
    private_class_method :normalize
  end
end
