module ProgramsHelper
  # Canonical types whose assets resolve to an openable URL.
  OPENABLE_CANONICALS = %i[web wildcard api].freeze

  # Build a clickable URL for a scope asset, or nil when the asset isn't a
  # web target (App Store IDs, CIDR ranges, source repos by name, etc.).
  # Prefers the platform-supplied `value` when it already looks like a URL;
  # otherwise derives one from the `asset` host string. Wildcards like
  # `*.example.com` open the bare apex so the browser has something to load.
  def asset_link(asset)
    return nil unless asset.is_a?(Hash)

    canonical = Programs::ScopeType.canonical_for(asset["type"])
    return nil unless OPENABLE_CANONICALS.include?(canonical)

    candidate = asset["value"].to_s.strip
    candidate = asset["asset"].to_s.strip if candidate.empty?
    return nil if candidate.empty?

    return candidate if candidate.match?(%r{\Ahttps?://}i)

    host = candidate.sub(%r{\A\*+\.}, "")
    host = host.split("/", 2).first.to_s
    return nil unless host.match?(/\A[a-z0-9][a-z0-9.\-]*\.[a-z]{2,}\z/i)

    "https://#{host}"
  end

  # Tags the safe subset of policy/description HTML the modal renders. Program
  # policy text is scraped upstream and untrusted, so it is sanitized
  # server-side (Hunter drops Scope's client-side DOMPurify) before display.
  PROGRAM_HTML_TAGS = %w[p br ul ol li strong em b i a code pre h1 h2 h3 h4 blockquote table thead tbody tr th td span].freeze
  PROGRAM_HTML_ATTRS = %w[href title].freeze

  def program_policy_html(html)
    sanitize html.to_s, tags: PROGRAM_HTML_TAGS, attributes: PROGRAM_HTML_ATTRS
  end
end
