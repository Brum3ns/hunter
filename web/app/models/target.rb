# PORO wrapping a normalized "alive" asset document read from MongoDB (see
# tmp/db_struct/alive.json). Not persisted in Postgres — construct from a hash
# via Target.new(hash). `verb` avoids clobbering Object#method.
class Target
  attr_reader :id, :attributes

  def initialize(attrs = {})
    @attributes = attrs.to_h.transform_keys(&:to_s)
    @id = @attributes["id"]
  end

  def metadata    = @attributes["metadata"] || {}
  def target      = @attributes["target"] || {}
  def http        = @attributes["http"] || {}
  def headers     = @attributes["headers"] || {}
  def csp         = @attributes["csp"] || {}
  def fingerprint = @attributes["fingerprint"] || {}
  def tech        = Array(@attributes["tech"])

  def host           = target["host"]
  def url            = target["url"]
  def input          = target["input"]
  def ip             = target["ip"]
  def port           = target["port"]
  def scheme         = target["scheme"]
  def path           = target["path"]
  def verb           = target["method"]
  def status_code    = http["status_code"]
  def title          = http["title"]
  def webserver      = http["webserver"]
  def content_type   = http["content_type"]
  def content_length = http["content_length"]
  def words          = http["words"]
  def lines          = http["lines"]
  def response_time  = http["response_time"]
  def program        = metadata["program"]
  def tool           = metadata["tool"]
  def scan_id        = metadata["scan_id"]
  def failed         = metadata["failed"]
  def seen_at        = metadata["date"]
  def page_type      = fingerprint["page_type"]
  def phash          = fingerprint["phash"]

  def status_family
    case status_code.to_i
    when 200..299 then "2xx"
    when 300..399 then "3xx"
    when 400..499 then "4xx"
    when 500..599 then "5xx"
    else "other"
    end
  end

  def as_json(*) = @attributes
end
