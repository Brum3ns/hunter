module Cves
  # Read + upsert access to the MongoDB `cves` collection. Mirrors
  # Vulnerabilities::MongoSource. The primary key is the string `id` field (the
  # CVE id), not Mongo's ObjectId. Reads swallow Mongo::Error (empty result);
  # upsert lets it propagate so the controller/job can react.
  module MongoSource
    module_function

    COLLECTION = "cves"

    INDEXES = [
      { key: { "id": 1 },                 name: "cve_id",       unique: true },
      { key: { "first_seen_at": 1 },      name: "first_seen_at" },
      { key: { "first_seen_at": 1, "id": 1 }, name: "first_seen_at_id" },
      { key: { "modified": -1 },          name: "modified" },
      { key: { "published": -1 },         name: "published" },
      { key: { "aliases": 1 },            name: "aliases" },
      { key: { "affected.ecosystem": 1 }, name: "affected_ecosystem" },
      { key: { "affected.package": 1 },   name: "affected_package" },
      { key: { "has_fix": 1 },            name: "has_fix" },
      { key: { "severity_score": -1 },    name: "severity_score" },
      { key: { "cwe_ids": 1 },            name: "cwe_ids" },
      { key: { "languages": 1 },          name: "languages" },
      { key: { "vendors": 1 },            name: "vendors" },
      { key: { "tags": 1 },               name: "tags" }
    ].freeze

    LIST_FILTER_KEYS = {
      "ecosystem" => "affected.ecosystem",
      "package"   => "affected.package",
      "language"  => "languages",
      "vendor"    => "vendors",
      "cwe"       => "cwe_ids",
      "tag"       => "tags"
    }.freeze

    SEVERITY_FLOORS = { "critical" => 9.0, "high" => 7.0, "medium" => 4.0, "low" => 0.1 }.freeze

    SEARCH_FIELDS = %w[id summary details].freeze

    def all(filters: {}, search: nil, page: 1, limit: 50)
      ensure_indexes!
      skip = ([page.to_i, 1].max - 1) * limit
      collection.find(build_filter(filters, search))
                .sort("modified" => -1).skip(skip).limit(limit)
                .to_a.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Cves::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {}, search: nil)
      collection.count_documents(build_filter(filters, search))
    rescue Mongo::Error => e
      Rails.logger.warn("Cves::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end

    def find(id)
      doc = collection.find("id" => id.to_s).first
      doc && normalize(doc)
    rescue Mongo::Error => e
      Rails.logger.warn("Cves::MongoSource#find failed (#{e.class}: #{e.message})")
      nil
    end

    # Distinct affected ecosystems with document counts, for the browse sidebar.
    # Returns [{ "ecosystem" => "npm", "count" => 1234 }, ...] sorted by count
    # desc. Read-only; swallows Mongo::Error like the other reads.
    def ecosystem_facets(limit: 50)
      collection.aggregate([
        { "$unwind" => "$affected" },
        { "$group"  => { "_id" => "$affected.ecosystem", "count" => { "$sum" => 1 } } },
        { "$match"  => { "_id" => { "$ne" => nil } } },
        { "$sort"   => { "count" => -1 } },
        { "$limit"  => limit }
      ]).map { |row| { "ecosystem" => row["_id"], "count" => row["count"] } }
    rescue Mongo::Error => e
      Rails.logger.warn("Cves::MongoSource#ecosystem_facets failed (#{e.class}: #{e.message})")
      []
    end

    def new_since(since: nil, since_id: nil, limit: 50, filters: {}, search: nil)
      ensure_indexes!
      cursor = cursor_filter(since, since_id)
      extra = build_filter(filters, search)
      filter = combine(cursor, extra)
      collection.find(filter).sort("first_seen_at" => 1, "id" => 1).limit(limit)
                .to_a.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Cves::MongoSource#new_since failed (#{e.class}: #{e.message})")
      []
    end

    def cursor_filter(since, since_id)
      if since && since_id
        { "$or" => [
            { "first_seen_at" => { "$gt" => since } },
            { "first_seen_at" => since, "id" => { "$gt" => since_id } }
          ] }
      elsif since
        { "first_seen_at" => { "$gt" => since } }
      else
        {}
      end
    end
    private_class_method :cursor_filter

    def combine(cursor, extra)
      return extra if cursor.empty?
      return cursor if extra.empty?
      { "$and" => [cursor, extra] }
    end
    private_class_method :combine

    # Upsert by CVE id. first_seen_at is stamped once (insert only); every sync
    # refreshes last_synced_at and the normalized body. Write errors propagate.
    def upsert(doc)
      normalized = doc.to_h.transform_keys(&:to_s)
      id = normalized.fetch("id")
      raise ArgumentError, "cve doc requires a non-blank id" if id.to_s.empty?
      now = Time.now.utc
      set = normalized.except("first_seen_at").merge("last_synced_at" => now)
      collection.update_one(
        { "id" => id },
        { "$set" => set, "$setOnInsert" => { "first_seen_at" => now } },
        upsert: true
      )
      id
    end

    def collection
      HunterMongo.collection(COLLECTION)
    end

    def ensure_indexes!
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
    end

    def build_filter(filters, search = nil)
      base = {}
      filters.to_h.each do |key, value|
        key = key.to_s
        if LIST_FILTER_KEYS.key?(key)
          values = Array(value).flat_map { |v| v.to_s.split(",") }.map(&:strip).reject(&:empty?)
          next if values.empty?
          base[LIST_FILTER_KEYS[key]] = values.size == 1 ? values.first : { "$in" => values }
        else
          case key
          when "has_fix"
            next if value.nil? || value == ""
            base["has_fix"] = ActiveModel::Type::Boolean.new.cast(value)
          when "min_severity"
            floor = SEVERITY_FLOORS[value.to_s.downcase]
            base["severity_score"] = { "$gte" => floor } if floor
          when "published_after"
            next if value.blank?
            (t = parse_time(value)) && (base["published"] = { "$gte" => t })
          when "modified_after"
            next if value.blank?
            (t = parse_time(value)) && (base["modified"] = { "$gte" => t })
          end
        end
      end
      if search.present?
        rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }
        base["$or"] = SEARCH_FIELDS.map { |field| { field => rx } }
      end
      base
    end
    private_class_method :build_filter

    def parse_time(value)
      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end
    private_class_method :parse_time

    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      hash.delete("_id")
      hash
    end
    private_class_method :normalize
  end
end
