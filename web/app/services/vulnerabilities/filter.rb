module Vulnerabilities
  # In-memory equivalent of Query's Mongo match, over a Ruby list of
  # Vulnerability instances. Used when Mongo is empty/unreachable and as a
  # unit-test seam. Facet field paths are the single source of truth shared
  # with Query via FACET_FIELDS.
  module Filter
    module_function

    # dimension name -> [section, key] reader on Vulnerability.
    FACET_FIELDS = {
      "severity" => %w[finding severity],
      "status"   => %w[report status],
      "tool"     => %w[metadata tool],
      "type"     => %w[finding type],
      "program"  => %w[metadata program]
    }.freeze

    SEARCH_READERS = [%w[finding name], %w[target host], %w[metadata program], %w[target url]].freeze

    def call(vulns, params)
      vulns.select { |v| keep?(v, params) }
    end

    # Per-dimension counts: each dimension counts the set filtered by every
    # OTHER active facet (and free text / dork / date), but NOT its own — so a
    # selected value still shows its siblings' availability.
    def facets(vulns, params)
      FACET_FIELDS.keys.each_with_object({}) do |dim, out|
        subset = vulns.select { |v| keep?(v, params, except: dim) }
        counts = Hash.new(0)
        section, key = FACET_FIELDS[dim]
        subset.each do |v|
          value = v.public_send(section)[key]
          next if value.to_s.empty?
          counts[value.to_s] += 1
        end
        out[dim] = counts
      end
    end

    def keep?(vuln, params, except: nil)
      return false unless matches_facets?(vuln, params, except)
      return false unless matches_date?(vuln, params)
      return false unless matches_search?(vuln, params)
      return false unless matches_dork?(vuln, params)
      true
    end

    def matches_facets?(vuln, params, except)
      FACET_FIELDS.each do |dim, (section, key)|
        next if dim == except
        values = Array(params[dim]).reject(&:blank?)
        next if values.empty?
        actual = vuln.public_send(section)[key].to_s
        return false unless values.any? { |val| val.casecmp?(actual) }
      end
      true
    end

    def matches_date?(vuln, params)
      date = vuln.metadata["date"].to_s
      from = params[:date_from].to_s
      to   = params[:date_to].to_s
      return false if from.present? && (date.empty? || date < from)
      return false if to.present?   && (date.empty? || date > to)
      true
    end

    def matches_search?(vuln, params)
      q = params[:q].to_s.strip.downcase
      return true if q.empty?
      SEARCH_READERS.any? do |section, key|
        vuln.public_send(section)[key].to_s.downcase.include?(q)
      end
    end

    def matches_dork?(vuln, params)
      expr = params[:dork_expression]
      return true unless expr
      expr.evaluate(vuln)
    end
  end
end
