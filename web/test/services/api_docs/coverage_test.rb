require "test_helper"

class ApiDocs::CoverageTest < ActiveSupport::TestCase
  # Verb+path pairs actually served under /api/v1, normalized to OpenAPI style
  # (:id -> {id}, no format suffix). Excludes HEAD/OPTIONS and the bare :verb.
  def route_pairs
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub(/\(\.:format\)$/, "")
      next unless path.start_with?("/api/v1")

      verb = route.verb.to_s.downcase
      next if verb.blank? || %w[head options].include?(verb)

      normalized = path.gsub(/:([a-z_]+)/) { "{#{Regexp.last_match(1)}}" }
      [verb, normalized]
    end.uniq
  end

  # Verb+path pairs the spec documents.
  def spec_pairs
    doc = ApiDocs::Spec.document(scopes: nil)
    doc["paths"].flat_map do |path, ops|
      ops.keys.select { |k| %w[get post put patch delete].include?(k) }.map { |verb| [verb, path] }
    end
  end

  test "every /api/v1 route is documented" do
    undocumented = route_pairs - spec_pairs
    assert_empty undocumented, "Routes missing from the OpenAPI spec: #{undocumented.inspect}"
  end

  test "every documented path exists as a route" do
    phantom = spec_pairs - route_pairs
    assert_empty phantom, "Spec documents nonexistent routes: #{phantom.inspect}"
  end

  test "every operation has a summary and tags" do
    doc = ApiDocs::Spec.document(scopes: nil)
    doc["paths"].each do |path, ops|
      ops.each do |verb, op|
        next unless %w[get post put patch delete].include?(verb)

        assert op["summary"].present?, "#{verb.upcase} #{path} is missing a summary"
        assert op["tags"].present?, "#{verb.upcase} #{path} is missing tags"
      end
    end
  end

  test "x-api-scope is present exactly where the controller declares one and matches it" do
    scoped = { "/api/v1/cves" => "cves", "/api/v1/vulnerabilities" => "vulnerabilities" }
    doc = ApiDocs::Spec.document(scopes: nil)
    scoped.each do |path, expected|
      op = doc.dig("paths", path, "get")
      assert_equal expected, op["x-api-scope"], "#{path} GET should declare x-api-scope #{expected}"
    end
    # A no-scope controller's operation must omit x-api-scope.
    assert_nil doc.dig("paths", "/api/v1/targets", "get", "x-api-scope")
    assert_nil doc.dig("paths", "/api/v1/programs/changes", "get", "x-api-scope")
  end
end
