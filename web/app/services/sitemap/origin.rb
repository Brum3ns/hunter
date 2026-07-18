require "uri"
require "digest"

module Sitemap
  # Pure origin/URL normalization shared by the target projection and the
  # endpoint matcher, so both compute an identical origin for the same asset.
  module Origin
    module_function

    DEFAULT_PORTS = { "http" => 80, "https" => 443 }.freeze

    def build(scheme:, host:, port: nil)
      host = host.to_s.strip.downcase
      return nil if host.empty?
      scheme = scheme.to_s.strip.downcase
      port = port.presence&.to_i || DEFAULT_PORTS[scheme]
      return nil unless port
      "#{scheme}://#{host}:#{port}"
    end

    def parse(raw_url)
      uri = URI.parse(raw_url.to_s.strip)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present?
      scheme = uri.scheme.downcase
      host = uri.host.downcase
      port = uri.port # URI fills the scheme default (80/443) when omitted
      origin = "#{scheme}://#{host}:#{port}"
      path = uri.path.presence || "/"
      url = +"#{origin}#{path}"
      url << "?#{uri.query}" if uri.query.present?
      { origin: origin, scheme: scheme, host: host, port: port, path: path, url: url }
    rescue URI::InvalidURIError
      nil
    end

    def digest(url, method)
      Digest::SHA256.digest("#{method.to_s.upcase}\0#{url}")
    end
  end
end
