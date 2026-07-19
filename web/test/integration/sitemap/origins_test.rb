require "test_helper"

class Sitemap::OriginsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host:, port: 443, scheme: "https", removed_at: nil)
    now = Time.current
    Sitemap::Target.create!(origin: "#{scheme}://#{host}:#{port}", scheme: scheme, host: host,
                            port: port, first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  def endpoint!(target, path, method: "GET", status: 200)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: method, status_code: status,
      url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", method),
      first_seen_at: now, last_seen_at: now)
  end

  test "index lists active origins ordered by host with endpoint counts" do
    a = target!(host: "www.atg.se"); endpoint!(a, "/x"); endpoint!(a, "/y")
    b = target!(host: "iam.atg.se"); endpoint!(b, "/z")
    target!(host: "gone.atg.se", removed_at: Time.current)

    get sitemap_root_path
    assert_response :success
    assert_select "[data-controller~=sitemap-tree]"
    assert_select "a[href=?]", sitemap_root_path # sidebar link present
    assert_match "iam.atg.se", @response.body
    assert_match "www.atg.se", @response.body
    assert_no_match "gone.atg.se", @response.body           # removed target hidden
    assert_select "[data-node] turbo-frame#origin_tree_#{a.id}[data-src=?]", sitemap_origin_tree_path(a)
  end

  test "q filters origins by host" do
    target!(host: "www.atg.se")
    b = target!(host: "presse.generali.fr"); endpoint!(b, "/x")
    get sitemap_root_path(q: "generali")
    assert_match "presse.generali.fr", @response.body
    assert_no_match "www.atg.se", @response.body
  end

  test "default hides origins with zero endpoints" do
    a = target!(host: "has.ep"); endpoint!(a, "/x")
    target!(host: "no.ep")
    get sitemap_root_path
    assert_match "has.ep", @response.body
    assert_no_match "no.ep", @response.body
  end

  test "min_count hides origins below the threshold" do
    a = target!(host: "one.ep"); endpoint!(a, "/x")
    b = target!(host: "three.ep"); endpoint!(b, "/a"); endpoint!(b, "/b"); endpoint!(b, "/c")
    get sitemap_root_path(min_count: 2)
    assert_match "three.ep", @response.body
    assert_no_match "one.ep", @response.body
  end

  test "method filter changes which origins qualify" do
    a = target!(host: "posts.only"); endpoint!(a, "/x", method: "POST")
    b = target!(host: "gets.only"); endpoint!(b, "/y", method: "GET")
    get sitemap_root_path(methods: ["POST"])
    assert_match "posts.only", @response.body
    assert_no_match "gets.only", @response.body
  end

  test "program filter restricts the origin list" do
    a = target!(host: "atg.host"); a.update!(program: "atg"); endpoint!(a, "/x")
    b = target!(host: "gen.host"); b.update!(program: "gen"); endpoint!(b, "/y")
    get sitemap_root_path(program: "atg")
    assert_match "atg.host", @response.body
    assert_no_match "gen.host", @response.body
  end

  test "tree applies the method filter to the built nodes" do
    t = target!(host: "t.host"); endpoint!(t, "/keep", method: "POST"); endpoint!(t, "/drop", method: "GET")
    get sitemap_origin_tree_path(t, methods: ["POST"])
    assert_response :success
    assert_match "keep", @response.body
    assert_no_match(/\bdrop\b/, @response.body) # not "backdrop" (sidebar markup) — whole word only
  end
end
