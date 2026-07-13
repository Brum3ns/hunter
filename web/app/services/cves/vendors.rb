require "cgi"

module Cves
  # Heuristically extracts a vendor/author from each affected package's purl
  # (preferred) or scoped package name. purl form: pkg:TYPE/NAMESPACE/NAME@VER —
  # the vendor is the namespace segment immediately before NAME. Pure; entries
  # with no derivable vendor contribute nothing.
  module Vendors
    module_function

    def call(affected)
      Array(affected).filter_map { |a| vendor(a.to_h) }.uniq
    end

    def vendor(entry)
      from_purl(entry["purl"]) || from_scope(entry["package"])
    end

    def from_purl(purl)
      return nil if purl.to_s.empty?
      body = purl.to_s.delete_prefix("pkg:").split(/[@?#]/).first.to_s
      segments = body.split("/")
      return nil if segments.size < 3 # type + namespace + name
      clean(segments[-2])
    end

    def from_scope(package)
      return nil unless package.to_s.start_with?("@")
      clean(package.to_s.split("/").first)
    end

    def clean(segment)
      value = CGI.unescape(segment.to_s).delete_prefix("@").strip
      value.empty? ? nil : value
    end
  end
end
