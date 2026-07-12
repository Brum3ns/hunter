# PORO wrapping a normalized CVE document read from MongoDB (`cves` collection).
# Not persisted in Postgres — construct from a hash via Cve.new(hash). Mirrors
# the Vulnerability model.
class Cve
  SCALARS = %w[id osv_id summary details published modified withdrawn has_fix
               first_seen_at last_synced_at].freeze
  LISTS   = %w[aliases severity cwe_ids ecosystems affected references].freeze

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
end
