# Resolves a technology name (as it appears in an httpx `tech[]` array) to a
# vendored Simple Icons record. Data is the pinned icons.json (see
# vendor/simple-icons/VERSION); no runtime gem.
#
# httpx/Wappalyzer names are noisy — versions ("nginx/1.18.0"), descriptor
# suffixes ("Apache HTTP Server"), ".js" branding ("Vue.js") — so `lookup` tries
# an ordered list of candidate spellings against an ALIASES table and the slug
# set, returning the first that resolves. ALIASES is the single place to add
# renamed/mismatched brands; every target slug here exists in the dataset.
module SimpleIcons
  module_function

  DATA_PATH = Rails.root.join("vendor", "simple-icons", "icons.json")

  # Names whose (cleaned) form still differs from the icon's slug.
  ALIASES = {
    "ruby on rails"      => "rubyonrails",
    "rails"              => "rubyonrails",
    "node.js"            => "nodedotjs",
    "vue.js"             => "vuedotjs",
    "next.js"            => "nextdotjs",
    "nuxt.js"            => "nuxt",
    "express.js"         => "express",
    "socket.io"          => "socketdotio",
    "google analytics"   => "googleanalytics",
    "google tag manager" => "googletagmanager",
    "google font api"    => "googlefonts",
    "google fonts"       => "googlefonts",
    "microsoft asp.net"  => "dotnet",
    "asp.net"            => "dotnet",
    "angularjs"          => "angular",
    "tomcat"             => "apachetomcat",
    "apache tomcat"      => "apachetomcat",
    "jetty"              => "eclipsejetty",
    "envoy"              => "envoyproxy"
  }.freeze

  # Generic descriptor words dropped so a brand keeps its icon, e.g.
  # "Apache HTTP Server" -> apache, "Cloudflare Bot Management" -> cloudflare.
  NOISE_WORDS = %w[
    http https httpd server web api cms framework proxy bot management
    service services engine platform the
  ].freeze

  def data
    @data ||= JSON.parse(File.read(DATA_PATH)).freeze
  end

  # normalize(title) => slug, built once from the dataset. Lets a tech name
  # match an icon by its human TITLE even when the slug is spelled differently
  # (e.g. "Node.js" -> title "Node.js" -> "nodejs" -> slug "nodedotjs"), which
  # resolves most ".js"/".io"/punctuation brands without a hand-written alias.
  # First title wins on the rare normalized-title collision.
  def title_index
    @title_index ||= data.each_with_object({}) do |(slug, icon), idx|
      key = normalize(icon["title"].to_s)
      idx[key] ||= slug
    end.freeze
  end

  def lookup(name)
    return nil if name.blank?

    candidates(name).each do |candidate|
      aliased = ALIASES[candidate]
      return record(aliased) if aliased && data.key?(aliased)

      slug = normalize(candidate)
      return record(slug) if data.key?(slug)

      # Fall back to matching the icon's human title (dataset-grounded, so no
      # false brand invented — the key must equal a real title's normalized form).
      by_title = title_index[slug]
      return record(by_title) if by_title
    end
    nil
  end

  def normalize(name)
    name.to_s.downcase.gsub(/[^a-z0-9]/, "")
  end

  # Ordered, de-duplicated candidate spellings tried against ALIASES + slugs:
  # raw, version-stripped, noise-word-stripped, and ".js"/".io" de-branded.
  def candidates(name)
    low = name.to_s.strip.downcase
    no_version = strip_version(low)
    [
      low,
      no_version,
      strip_noise(no_version),
      low.gsub(/\.js\b/, "dotjs").gsub(/\.io\b/, "dotio")
    ].map(&:strip).reject(&:empty?).uniq
  end
  private_class_method :candidates

  # Drop a trailing version token and anything after it ("nginx/1.18.0" -> nginx,
  # "WordPress 6.4" -> wordpress). The \s guard leaves embedded digits intact
  # (e.g. "Web3", "Log4j").
  def strip_version(str)
    str.split(%r{[/:]}).first.to_s.sub(/\s+v?\d[\d.]*.*\z/, "").strip
  end
  private_class_method :strip_version

  def strip_noise(str)
    str.split(/[\s_-]+/).reject { |w| w.empty? || NOISE_WORDS.include?(w) }.join(" ")
  end
  private_class_method :strip_noise

  def record(slug)
    icon = data[slug]
    { slug: slug, title: icon["title"], hex: icon["hex"], path: icon["path"] }
  end
  private_class_method :record
end
