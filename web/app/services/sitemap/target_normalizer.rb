module Sitemap
  # Raw `alive` Mongo doc -> target upsert attrs, or nil if no usable origin.
  module TargetNormalizer
    module_function

    def call(doc)
      doc = doc.to_h.transform_keys(&:to_s)
      target = (doc["target"] || {})
      origin = Sitemap::Origin.build(scheme: target["scheme"], host: target["host"], port: target["port"])
      return nil unless origin
      { origin: origin,
        scheme: target["scheme"].to_s.downcase,
        host: target["host"].to_s.downcase,
        port: (target["port"].presence || Sitemap::Origin::DEFAULT_PORTS[target["scheme"].to_s.downcase]).to_i,
        program: (doc["metadata"] || {})["program"],
        alive_mongo_id: doc["_id"]&.to_s }
    end
  end
end
