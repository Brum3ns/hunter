module Vulnerabilities
  # Single entry point for the vulnerabilities index. Translates filter params
  # into a Mongo query (match + $facet counts + sorted page) and returns only
  # the matching rows. Falls back to the in-memory Filter+Sort pipeline when the
  # collection is empty or Mongo is unreachable, so the page always renders.
  class Query
    Result = Struct.new(
      :findings, :total, :facets, :page, :per_page, :has_next, :sort_key, :sort_dir,
      keyword_init: true
    )

    DEFAULT_PER_PAGE = 50
    MAX_PER_PAGE     = 100

    # Facet dimension -> Mongo field. Shared shape with Filter::FACET_FIELDS.
    FACET_FIELDS = {
      "severity" => "finding.severity",
      "status"   => "report.status",
      "tool"     => "metadata.tool",
      "type"     => "finding.type",
      "program"  => "metadata.program"
    }.freeze

    SEARCH_FIELDS = %w[finding.name target.host metadata.program target.url].freeze

    def self.call(params) = new(params).call

    def initialize(params)
      @params = params
    end

    def call
      if mongo_usable?
        MongoSource.ensure_indexes!
        query_mongo
      else
        query_fallback
      end
    rescue Mongo::Error => e
      Rails.logger.warn("Vulnerabilities::Query failed, falling back (#{e.class}: #{e.message})")
      query_fallback
    end

    private

    def mongo_usable?
      return false unless HunterMongo.healthy?
      collection.estimated_document_count.positive?
    rescue Mongo::Error
      false
    end

    def collection = MongoSource.collection

    # --- mongo path -------------------------------------------------------

    def query_mongo
      match = match_doc
      total = collection.count_documents(match)
      offset = (page - 1) * per_page

      findings = fetch_page(match, offset).map { |doc| Vulnerability.new(normalize(doc)) }

      Result.new(
        findings: findings,
        total:    total,
        facets:   facet_counts_mongo,
        page:     page,
        per_page: per_page,
        has_next: (offset + findings.size) < total,
        sort_key: sort_key,
        sort_dir: sort_dir
      )
    end

    def fetch_page(match, offset)
      pipeline = [{ "$match" => match }]
      # Severity sort needs a numeric rank the documents don't carry.
      if sort_key == "severity"
        branches = Sort::SEVERITY_RANK.map { |sev, rank| { "case" => { "$eq" => ["$finding.severity", sev] }, "then" => rank } }
        pipeline << { "$addFields" => { "_sevrank" => { "$switch" => { "branches" => branches, "default" => 0 } } } }
      end
      pipeline += [
        { "$sort" => Sort.mongo_doc(sort_key, sort_dir) },
        { "$skip" => offset },
        { "$limit" => per_page }
      ]
      collection.aggregate(pipeline).to_a
    end

    # One aggregation, one sub-pipeline per dimension, each matching on all
    # OTHER active filters (match_doc(except: dim)) then grouping by the field.
    def facet_counts_mongo
      facets = FACET_FIELDS.each_with_object({}) do |(dim, field), spec|
        spec[dim] = [
          { "$match" => match_doc(except: dim) },
          { "$group" => { "_id" => "$#{field}", "n" => { "$sum" => 1 } } }
        ]
      end
      raw = collection.aggregate([{ "$facet" => facets }]).first || {}
      FACET_FIELDS.keys.each_with_object({}) do |dim, out|
        counts = {}
        Array(raw[dim]).each do |row|
          id = row["_id"]
          next if id.to_s.empty?
          counts[id.to_s] = row["n"]
        end
        out[dim] = counts
      end
    end

    # match_doc(except:) omits one dimension's own facet clause so its counts
    # reflect availability given the OTHER filters.
    def match_doc(except: nil)
      doc = {}
      add_search(doc)
      add_dork(doc)
      FACET_FIELDS.each do |dim, field|
        next if dim == except
        values = Array(@params[dim]).reject(&:blank?)
        doc[field] = { "$in" => values } unless values.empty?
      end
      add_date_range(doc)
      doc
    end

    def add_search(doc)
      q = @params[:q].to_s.strip
      return if q.empty?
      re = Regexp.escape(q)
      doc["$or"] = SEARCH_FIELDS.map { |f| { f => { "$regex" => re, "$options" => "i" } } }
    end

    def add_dork(doc)
      expr = @params[:dork_expression]
      return unless expr
      clause = expr.to_mongo
      return unless clause
      doc["$and"] = (doc["$and"] || []) + [clause]
    end

    def add_date_range(doc)
      from = @params[:date_from].to_s
      to   = @params[:date_to].to_s
      return if from.empty? && to.empty?
      range = {}
      range["$gte"] = from unless from.empty?
      range["$lte"] = to   unless to.empty?
      doc["metadata.date"] = range
    end

    # --- fallback path ----------------------------------------------------

    def query_fallback
      all = fallback_source
      filtered = Filter.call(all, @params)
      sorted = filtered.sort(&Sort.comparator(sort_key, sort_dir))
      offset = (page - 1) * per_page
      window = sorted[offset, per_page] || []

      Result.new(
        findings: window,
        total:    sorted.size,
        facets:   Filter.facets(all, @params),
        page:     page,
        per_page: per_page,
        has_next: (offset + window.size) < sorted.size,
        sort_key: sort_key,
        sort_dir: sort_dir
      )
    end

    # Seam: the set the fallback filters over. Empty when Mongo is unreachable
    # (dev path); reads swallow Mongo errors to []. Overridable in tests.
    def fallback_source
      collection.find.limit(MAX_PER_PAGE * 5).map { |doc| Vulnerability.new(normalize(doc)) }
    rescue Mongo::Error
      []
    end

    # --- shared helpers ---------------------------------------------------

    def sort_key = Sort.resolve_key(@params[:sort])
    def sort_dir = Sort.resolve_dir(sort_key, @params[:dir])

    def page
      @page ||= [@params[:page].to_i, 1].max
    end

    def per_page = DEFAULT_PER_PAGE

    def normalize(doc)
      hash = doc.to_h.transform_keys(&:to_s)
      oid = hash.delete("_id")
      hash["id"] = oid.to_s if oid
      hash
    end
  end
end
