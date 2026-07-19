module Sitemap
  # Turns a flat list of endpoints into a nested path-segment tree (a trie),
  # mirroring the Burp/Caido site tree. Pure: no DB, no view concerns. Consumers
  # pass any objects responding to #id/#path/#method/#status_code.
  module Tree
    module_function

    Node = Struct.new(:label, :full_path, :endpoint, :children, keyword_init: true) do
      def folder?   = children.any?
      def endpoint? = !endpoint.nil?
    end

    # Root-level nodes, sorted (folders first, then leaves; each alphabetical).
    def build(endpoints)
      root = {}
      endpoints.sort_by(&:id).each { |ep| insert(root, ep) }
      to_nodes(root)
    end

    # --- internals ---

    def insert(root, endpoint)
      path = endpoint.path.to_s
      path = "/#{path}" unless path.start_with?("/")
      parts = path.sub(%r{\A/}, "").split("/").reject(&:empty?)

      if parts.empty? # the "/" root request
        e = (root["/"] ||= entry("/", "/"))
        e[:endpoint] ||= endpoint
        return
      end

      dir = path.end_with?("/")
      level = root
      path_parts = []
      parts.each_with_index do |part, i|
        last = i == parts.length - 1
        is_dir = last ? dir : true
        label = is_dir ? "#{part}/" : part
        path_parts << part
        full = "/" + path_parts.join("/") + (is_dir ? "/" : "")
        e = (level[label] ||= entry(label, full))
        e[:endpoint] ||= endpoint if last
        level = e[:children]
      end
    end
    private_class_method :insert

    def entry(label, full) = { label: label, full_path: full, endpoint: nil, children: {} }
    private_class_method :entry

    def to_nodes(level)
      nodes = level.values.map do |e|
        Node.new(label: e[:label], full_path: e[:full_path], endpoint: e[:endpoint],
                 children: to_nodes(e[:children]))
      end
      nodes.sort_by { |n| [n.folder? ? 0 : 1, n.label.downcase] }
    end
    private_class_method :to_nodes
  end
end
