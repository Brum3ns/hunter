# PORO wrapping a normalized CVE document read from MongoDB (`cves` collection).
# Not persisted in Postgres — construct from a hash via Cve.new(hash). Mirrors
# the Vulnerability model.
class Cve
  SCALARS = %w[id osv_id summary details published modified withdrawn has_fix
               severity_score severity_level first_seen_at last_synced_at].freeze
  LISTS   = %w[aliases severity cwe_ids ecosystems languages vendors tags
               affected references].freeze

  CORE_FIELDS = %w[id summary severity_level severity_score ecosystems languages
                   vendors cwe_ids tags has_fix published modified].freeze

  attr_reader :attributes

  def initialize(attrs = {})
    @attributes = attrs.to_h.transform_keys(&:to_s)
  end

  SCALARS.each { |k| define_method(k) { @attributes[k] } }
  LISTS.each   { |k| define_method(k) { @attributes[k] || [] } }

  def chain
    @attributes["chain"] || {}
  end

  def as_json(*)
    @attributes
  end

  # Compact serialization for LLM fetches: core identifying + triage fields plus
  # the fix chain, omitting the large `details` body. Full doc via as_json.
  def as_core_json
    @attributes.slice(*CORE_FIELDS).merge("chain" => chain)
  end
end
