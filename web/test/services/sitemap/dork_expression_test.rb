require "test_helper"

class Sitemap::DorkExpressionTest < ActiveSupport::TestCase
  setup do
    @hit_target = target!(host: "api.example.com", program: "acme")
    @miss_target = target!(host: "other.test", port: 80, scheme: "http", program: "beta")
    @hit = endpoint!(
      target: @hit_target,
      path: "/admin/100%_safe",
      url: "#{@hit_target.origin}/admin/100%_safe?token=1",
      method: "POST",
      status: 503,
      length: 2048,
      content_type: "application/json",
      seen: Time.utc(2026, 7, 10, 12)
    )
    @miss = endpoint!(
      target: @miss_target,
      path: "/public",
      method: "GET",
      status: 200,
      length: 128,
      content_type: "text/html",
      seen: Time.utc(2026, 7, 9, 12)
    )
  end

  def target!(host:, port: 443, scheme: "https", program: nil)
    now = Time.current
    Sitemap::Target.create!(
      origin: "#{scheme}://#{host}:#{port}", scheme: scheme, host: host,
      port: port, program: program, first_seen_at: now, last_seen_at: now
    )
  end

  def endpoint!(target:, path:, url: nil, method: "GET", status: 200,
                length: nil, content_type: nil, seen: Time.current)
    url ||= "#{target.origin}#{path}"
    Sitemap::Endpoint.create!(
      target: target, origin: target.origin, url: url, path: path,
      method: method, status_code: status, content_length: length,
      content_type: content_type, url_digest: Sitemap::Origin.digest(url, method),
      first_seen_at: seen, last_seen_at: seen
    )
  end

  def parse(query) = Sitemap::SearchParser.call(query)

  def relation
    Sitemap::Endpoint.active.joins(:target).order(:id)
  end

  def search(query)
    expression = parse(query).expression
    relation.where(expression.to_arel).to_a
  end

  test "all public keys map to their intended columns" do
    queries = %w[
      host:api.example.com origin:api.example.com program:acme path:admin
      url:token content_type:json method:post scheme:https port:443
      status:503 length:2048 has_query:yes seen:2026-07-10
    ]

    queries.each do |query|
      assert_includes search(query), @hit, query
      assert_not_includes search(query), @miss, query
    end
  end

  test "wildcards are anchored and SQL wildcard characters stay literal" do
    decoy = endpoint!(target: @hit_target, path: "/admin/100XXsafe")

    assert_equal [ @hit ], search("host:*.example.com path:100%_safe")
    assert_not_includes search("path:100%_safe"), decoy
    assert_equal [ @hit ], search("method:P*")
  end

  test "numeric comparisons compose" do
    assert_equal [ @hit ], search("status:>=500 length:>1024 port:<=443")
  end

  test "date comparisons use UTC calendar-day boundaries" do
    assert_equal [ @hit ], search("seen:2026-07-10")
    assert_equal [ @hit ], search("seen:>2026-07-09")
    assert_equal [ @miss ], search("seen:<2026-07-10")
    assert_equal [ @hit, @miss ], search("seen:<=2026-07-10")
  end

  test "boolean predicates support both polarities" do
    root = endpoint!(target: @hit_target, path: "/")

    assert_equal [ @hit ], search("has_query:yes")
    assert_equal [ @miss, root ].sort_by(&:id), search("has_query:no").sort_by(&:id)
    assert_equal [ root ], search("root:yes")
    assert_equal [ @hit, @miss ], search("root:no")
  end

  test "positive-root metadata works through nested expressions" do
    positive = parse("method:POST AND (root:yes OR path:/admin)").expression
    negative = parse("root:no OR path:/admin").expression

    assert positive.includes_positive_root?
    refute negative.includes_positive_root?
  end

  test "AND binds tighter than OR in generated predicates" do
    assert_equal [ @hit ], search("root:yes OR method:POST AND status:503")
  end

  test "invalid typed values safely match nothing" do
    %w[status:nope length:1.2 has_query:maybe root:maybe seen:yesterday].each do |query|
      assert_empty search(query), query
    end
  end
end
