module Sitemap
  # Streams endpoint URLs for a job-target selection. Reuses the sitemap search
  # parser + endpoint filter so a selection's `q` means exactly what it does on
  # the Sitemap page. Reads from Postgres in batches (find_each) so memory stays
  # flat regardless of the row count.
  module EndpointResolver
    module_function

    def each_url(q: nil, ids: nil, exclude_ids: nil, &block)
      return enum_for(:each_url, q: q, ids: ids, exclude_ids: exclude_ids) unless block
      scope(q, ids, exclude_ids).select(:id, :url).find_each(batch_size: 1_000) do |ep|
        block.call(ep.url) if ep.url.to_s.strip.present?
      end
    end

    def count_urls(q: nil, ids: nil, exclude_ids: nil)
      scope(q, ids, exclude_ids).count
    end

    def scope(q, ids, exclude_ids)
      parsed = Sitemap::SearchParser.call(q)
      s = Sitemap::EndpointFilter.apply(
        Sitemap::Endpoint.active, {},
        free_text: parsed.free_text, expression: parsed.expression
      )
      s = s.where(id: Array(ids)) if ids.present?
      s = s.where.not(id: Array(exclude_ids)) if exclude_ids.present?
      s
    end
    private_class_method :scope
  end
end
