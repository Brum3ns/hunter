# web/app/services/cves/osv_client.rb
require "net/http"
require "json"
require "stringio"
require "zip"

module Cves
  # Fetches OSV.dev's per-ecosystem bulk dumps. OSV's query API cannot enumerate
  # the database, so we mirror the storage bucket: ecosystems.txt lists the
  # ecosystems, and <ecosystem>/all.zip holds one JSON file per record.
  class OsvClient
    DEFAULT_BASE = "https://osv-vulnerabilities.storage.googleapis.com".freeze
    MAX_REDIRECTS = 3

    def initialize(base_url: DEFAULT_BASE)
      @base = base_url.chomp("/")
    end

    # Returns the list of ecosystem names (e.g. "npm", "PyPI", "Alpine:v3.10").
    def ecosystems
      get("#{@base}/ecosystems.txt").each_line.map(&:strip).reject(&:empty?)
    end

    # Yields each record (parsed JSON hash) in the given ecosystem's all.zip.
    def each_record(ecosystem)
      data = get("#{@base}/#{ecosystem}/all.zip")
      Zip::File.open_buffer(StringIO.new(data)) do |zip|
        zip.each do |entry|
          next unless entry.name.end_with?(".json")
          yield JSON.parse(entry.get_input_stream.read)
        end
      end
    end

    private

    def get(url, redirects = MAX_REDIRECTS)
      response = Net::HTTP.get_response(URI(url))
      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        raise "too many redirects for #{url}" if redirects <= 0
        get(response["location"], redirects - 1)
      else
        raise "OSV fetch failed for #{url}: #{response.code} #{response.message}"
      end
    end
  end
end
