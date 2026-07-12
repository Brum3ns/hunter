# web/test/services/cves/osv_client_test.rb
require "test_helper"
require "zip"
require "stringio"

class Cves::OsvClientTest < ActiveSupport::TestCase
  # Build an in-memory all.zip with one JSON record per entry.
  def zip_bytes(records)
    buffer = StringIO.new
    Zip::OutputStream.write_buffer(buffer) do |zos|
      records.each_with_index do |rec, i|
        zos.put_next_entry("#{i}.json")
        zos.write(JSON.generate(rec))
      end
      zos.put_next_entry("README.txt") # a non-json entry must be skipped
      zos.write("ignore me")
    end
    buffer.string
  end

  test "ecosystems parses the newline list and drops blanks" do
    client = Cves::OsvClient.new
    stub_methods(client, get: "npm\nPyPI\n\nGo\n") do
      assert_equal %w[npm PyPI Go], client.ecosystems
    end
  end

  test "each_record yields parsed JSON for every .json entry and skips others" do
    client = Cves::OsvClient.new
    payload = zip_bytes([{ "id" => "OSV-1" }, { "id" => "OSV-2" }])
    yielded = []
    stub_methods(client, get: payload) do
      client.each_record("npm") { |rec| yielded << rec["id"] }
    end
    assert_equal %w[OSV-1 OSV-2], yielded.sort
  end

  test "each_record requests the ecosystem all.zip url" do
    client = Cves::OsvClient.new(base_url: "https://osv.example")
    requested = nil
    getter = ->(url) { requested = url; zip_bytes([]) }
    stub_methods(client, get: getter) do
      client.each_record("Alpine:v3.10") { |_| }
    end
    assert_equal "https://osv.example/Alpine:v3.10/all.zip", requested
  end
end
