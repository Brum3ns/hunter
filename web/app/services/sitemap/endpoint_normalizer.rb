module Sitemap
  # Raw katana/wayback Mongo doc -> endpoint upsert attrs, or nil if no usable
  # URL. katana carries request/response detail; wayback is URL-only (GET).
  module EndpointNormalizer
    module_function

    def call(doc, source:)
      doc = doc.to_h.transform_keys(&:to_s)
      raw_url = raw_url_for(doc, source)
      parsed = Sitemap::Origin.parse(raw_url)
      return nil unless parsed

      attrs = { origin: parsed[:origin], url: parsed[:url], path: parsed[:path],
                method: method_for(doc, source), source: source,
                status_code: nil, content_length: nil, content_type: nil,
                source_mongo_id: doc["_id"]&.to_s }

      if source == "katana"
        resp = doc["response"] || {}
        attrs[:status_code]    = resp["status_code"]
        attrs[:content_length] = resp["content_length"]
        attrs[:content_type]   = (resp["headers"] || {})["Content-Type"]
      end
      attrs
    end

    def raw_url_for(doc, source)
      if source == "katana"
        (doc["request"] || {})["endpoint"]
      else
        doc["url"].presence || (doc["request"] || {})["endpoint"]
      end
    end
    private_class_method :raw_url_for

    def method_for(doc, source)
      m = source == "katana" ? (doc["request"] || {})["method"] : nil
      m.presence&.upcase || "GET"
    end
    private_class_method :method_for
  end
end
