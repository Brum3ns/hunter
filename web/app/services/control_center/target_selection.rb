require "set"

module ControlCenter
  # Turns a client selection descriptor into a target string list by dispatching
  # each entry to the owning module's resolver, then unioning + de-duping. Never
  # queries a data store directly. Streaming keeps memory flat for huge sends.
  module TargetSelection
    module_function

    SOURCES = %w[targets sitemap].freeze

    class InvalidSelection < StandardError; end

    def validate!(selections)
      normalize(selections).each { |sel| source_of(sel) }
      true
    end

    def count(selections, manual_targets = [])
      total = manual_list(manual_targets).size
      normalize(selections).each do |sel|
        args = resolve_args(sel)
        total += case source_of(sel)
                 when "targets" then Targets::MongoSource.count_hosts(**args)
                 when "sitemap" then Sitemap::EndpointResolver.count_urls(**args)
                 end
      end
      total
    end

    def stream(selections, manual_targets = [], &block)
      raise ArgumentError, "block required" unless block
      seen = Set.new
      emit = lambda do |value|
        v = value.to_s.strip
        return if v.empty? || seen.include?(v)
        seen << v
        block.call(v)
      end
      manual_list(manual_targets).each { |t| emit.call(t) }
      normalize(selections).each do |sel|
        args = resolve_args(sel)
        case source_of(sel)
        when "targets" then Targets::MongoSource.each_host(**args) { |h| emit.call(h) }
        when "sitemap" then Sitemap::EndpointResolver.each_url(**args) { |u| emit.call(u) }
        end
      end
      seen.size
    end

    def sample(selections, manual_targets = [], limit: 50)
      out = []
      catch(:done) do
        stream(selections, manual_targets) do |v|
          out << v
          throw :done if out.size >= limit
        end
      end
      out
    end

    # ---- internals ----

    def normalize(selections)
      Array(selections).map do |sel|
        h = sel.respond_to?(:to_unsafe_h) ? sel.to_unsafe_h : sel
        h.to_h.symbolize_keys
      end
    end
    private_class_method :normalize

    def source_of(sel)
      source = sel[:source].to_s
      raise InvalidSelection, "unknown source: #{source.inspect}" unless SOURCES.include?(source)
      source
    end
    private_class_method :source_of

    def resolve_args(sel)
      { q: sel[:q], ids: sel[:ids], exclude_ids: sel[:exclude_ids] }
    end
    private_class_method :resolve_args

    def manual_list(manual_targets)
      Array(manual_targets).map { |t| t.to_s.strip }.reject(&:empty?)
    end
    private_class_method :manual_list
  end
end
