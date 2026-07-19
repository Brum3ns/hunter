module Sitemap
  # Raw `crawl` Mongo doc -> endpoint upsert attrs, or nil if there is no usable
  # URL. Shape follows tmp/db_struct/crawl.json: the URL is `request.url`, the
  # HTTP method is `request.method`, and response detail is flat under
  # `response.{status_code,content_length,content_type}`.
  module EndpointNormalizer
    module_function

    def call(doc)
      doc = doc.to_h.transform_keys(&:to_s)
      request = doc["request"] || {}
      parsed = Sitemap::Origin.parse(request["url"])
      return nil unless parsed

      response = doc["response"] || {}
      { origin: parsed[:origin], url: parsed[:url], path: parsed[:path],
        method: request["method"].presence&.upcase || "GET",
        status_code: response["status_code"],
        content_length: response["content_length"],
        content_type: response["content_type"],
        crawl_mongo_id: (doc["_id"] || doc["id"])&.to_s }
    end
  end
end
