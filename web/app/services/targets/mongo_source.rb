module Targets
  # Read-only access to the MongoDB `alive` collection (httpx probe output; see
  # tmp/db_struct/alive.json). Mirrors Vulnerabilities::MongoSource but without
  # writes. Reads never raise to the caller — a Mongo outage yields empty/nil.
  module MongoSource
    module_function

    COLLECTION = ENV.fetch("MONGO_ALIVE_COLLECTION", "alive")

    INDEXES = [
      { key: { "target.host": 1 },      name: "target_host" },
      { key: { "target.ip": 1 },        name: "target_ip" },
      { key: { "http.status_code": 1 }, name: "http_status_code" },
      { key: { "metadata.program": 1 }, name: "metadata_program" },
      { key: { "metadata.date": -1 },   name: "metadata_date" }
    ].freeze

    # Public filter key -> nested Mongo field. Anything else is ignored.
    FILTER_KEYS = {
      "program" => "metadata.program",
      "status"  => "http.status_code"
    }.freeze

    # Free-text search matches any of these (case-insensitive).
    SEARCH_FIELDS = %w[target.host target.ip http.title tech].freeze

    # Public sort key -> Mongo field. Unknown keys fall back to DEFAULT_SORT.
    SORT_FIELDS = {
      "host"   => "target.host",
      "ip"     => "target.ip",
      "port"   => "target.port",
      "status" => "http.status_code",
      "title"  => "http.title",
      "date"   => "metadata.date"
    }.freeze
    DEFAULT_SORT = "date"

    def all(filters: {}, search: nil, expression: nil, sort: DEFAULT_SORT, dir: "desc", page: 1, limit: 50)
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      skip = ([page.to_i, 1].max - 1) * limit
      docs = collection.find(build_filter(filters, search, expression))
                       .sort(sort_spec(sort, dir))
                       .skip(skip)
                       .limit(limit)
                       .to_a
      docs.map { |doc| normalize(doc) }
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#all failed (#{e.class}: #{e.message})")
      []
    end

    def count(filters: {}, search: nil, expression: nil)
      collection.count_documents(build_filter(filters, search, expression))
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#count failed (#{e.class}: #{e.message})")
      0
    end

    # Stream the host string of every asset matching a selection. Yields each
    # target.host; returns an Enumerator when called without a block. A Mongo
    # outage logs and returns false (callers must not treat false as "empty").
    def each_host(q: nil, ids: nil, exclude_ids: nil, &block)
      return enum_for(:each_host, q: q, ids: ids, exclude_ids: exclude_ids) unless block
      HunterMongo.ensure_indexes_once!(COLLECTION, INDEXES)
      collection.find(selection_filter(q, ids, exclude_ids))
                .projection("target.host" => 1)
                .each do |doc|
        host = doc.to_h.dig("target", "host") || doc.dig("target", "host")
        block.call(host) if host.to_s.strip.present?
      end
      true
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#each_host failed (#{e.class}: #{e.message})")
      false
    end

    # Count assets matching a selection (one per row, pre-dedup). 0 on outage.
    def count_hosts(q: nil, ids: nil, exclude_ids: nil)
      collection.count_documents(selection_filter(q, ids, exclude_ids))
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#count_hosts failed (#{e.class}: #{e.message})")
      0
    end

    def find(id)
      oid = to_object_id(id)
      return nil unless oid
      doc = collection.find(_id: oid).first
      doc && normalize(doc)
    rescue Mongo::Error => e
      Rails.logger.warn("Targets::MongoSource#find failed (#{e.class}: #{e.message})")
      nil
    end

    def collection
      HunterMongo.collection(COLLECTION)
    end

    def sort_spec(sort, dir)
      field = SORT_FIELDS[sort.to_s] || SORT_FIELDS[DEFAULT_SORT]
      { field => (dir.to_s == "asc" ? 1 : -1) }
    end
    private_class_method :sort_spec

    # Combine three clause sources — mapped exact filters, the free-text $or, and
    # the dork AST — under one top-level $and. $and is required because the
    # free-text search and an OR dork can each emit a top-level $or, and a Mongo
    # document can hold only one $or key. Collapses to the lone clause (or {}).
    def build_filter(filters, search = nil, expression = nil)
      clauses = []

      filters.to_h.each do |key, value|
        next if value.blank?
        mongo_key = FILTER_KEYS[key.to_s]
        clauses << { mongo_key => value } if mongo_key
      end

      if search.present?
        rx = { "$regex" => Regexp.escape(search.to_s), "$options" => "i" }
        clauses << { "$or" => SEARCH_FIELDS.map { |field| { field => rx } } }
      end

      dork = expression&.to_mongo
      clauses << dork if dork

      case clauses.length
      when 0 then {}
      when 1 then clauses.first
      else { "$and" => clauses }
      end
    end
    private_class_method :build_filter

    # A selection is a dork/free-text query plus optional include/exclude ids.
    # Reuses build_filter for the query part and $in/$nin for the id parts,
    # combining under $and (or collapsing to the single clause).
    def selection_filter(q, ids, exclude_ids)
      parsed = SearchParser.call(q)
      query  = build_filter({}, parsed.free_text.presence, parsed.expression)

      clauses = []
      clauses << query unless query.empty?
      oids = Array(ids).filter_map { |i| to_object_id(i) }
      clauses << { "_id" => { "$in" => oids } } if oids.any?
      exs = Array(exclude_ids).filter_map { |i| to_object_id(i) }
      clauses << { "_id" => { "$nin" => exs } } if exs.any?

      case clauses.length
      when 0 then {}
      when 1 then clauses.first
      else { "$and" => clauses }
      end
    end
    private_class_method :selection_filter

    def to_object_id(id)
      BSON::ObjectId.from_string(id.to_s)
    rescue BSON::Error::InvalidObjectId
      nil
    end
    private_class_method :to_object_id

    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      oid = hash.delete("_id")
      hash["id"] = oid.to_s if oid
      hash
    end
    private_class_method :normalize
  end
end
