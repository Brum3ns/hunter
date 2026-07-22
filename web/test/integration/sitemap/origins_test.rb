require "test_helper"

class Sitemap::OriginsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host:, port: 443, scheme: "https", removed_at: nil)
    now = Time.current
    Sitemap::Target.create!(origin: "#{scheme}://#{host}:#{port}", scheme: scheme, host: host,
                            port: port, first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  def endpoint!(target, path, method: "GET", status: 200, url: nil, content_type: nil)
    now = Time.current
    url ||= "#{target.origin}#{path}"
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: url,
      path: path, method: method, status_code: status, content_type: content_type,
      url_digest: Sitemap::Origin.digest(url, method),
      first_seen_at: now, last_seen_at: now)
  end

  test "index lists active origins ordered by host with endpoint counts" do
    a = target!(host: "www.atg.se"); endpoint!(a, "/x"); endpoint!(a, "/y")
    b = target!(host: "iam.atg.se"); endpoint!(b, "/z")
    target!(host: "gone.atg.se", removed_at: Time.current)

    get targets_sitemap_path
    assert_response :success
    assert_select "[data-controller~=sitemap-tree]"
    assert_select "a[href=?]", targets_sitemap_path # department tab present
    assert_match "iam.atg.se", @response.body
    assert_match "www.atg.se", @response.body
    assert_no_match "gone.atg.se", @response.body           # removed target hidden
    assert_select "[data-node] turbo-frame#origin_tree_#{a.id}[data-src=?]", targets_sitemap_origin_tree_path(a)
  end

  test "renders as the Sitemap tab in the Target department" do
    target = target!(host: "tab.example.com"); endpoint!(target, "/x")

    get "/targets/sitemap"

    assert_response :success
    assert_select "nav[aria-label='Target sections']" do
      assert_select "a[href=?]:not([aria-current])", targets_path, text: "Target"
      assert_select "a[href=?][aria-current=page]", targets_sitemap_path, text: "Sitemap"
    end
    assert_select "aside a[title=Target][href=?][aria-current=page]", targets_path, count: 1
    assert_select "aside a[title=Sitemap]", count: 0
  end

  test "legacy sitemap URL redirects to the Target tab and preserves filters" do
    get "/sitemap", params: { q: "method:POST", include_root: "1" }

    assert_response :moved_permanently
    location = URI.parse(response.location)
    assert_equal targets_sitemap_path, location.path
    assert_equal({ "q" => "method:POST", "include_root" => "1" },
                 Rack::Utils.parse_nested_query(location.query))
  end

  test "q filters origins by host" do
    target!(host: "www.atg.se")
    b = target!(host: "presse.generali.fr"); endpoint!(b, "/x")
    get targets_sitemap_path(q: "generali")
    assert_match "presse.generali.fr", @response.body
    assert_no_match "www.atg.se", @response.body
  end

  test "default hides origins with zero endpoints" do
    a = target!(host: "has.ep"); endpoint!(a, "/x")
    target!(host: "no.ep")
    get targets_sitemap_path
    assert_match "has.ep", @response.body
    assert_no_match "no.ep", @response.body
  end

  test "min_count hides origins below the threshold" do
    a = target!(host: "one.ep"); endpoint!(a, "/x")
    b = target!(host: "three.ep"); endpoint!(b, "/a"); endpoint!(b, "/b"); endpoint!(b, "/c")
    get targets_sitemap_path(min_count: 2)
    assert_match "three.ep", @response.body
    assert_no_match "one.ep", @response.body
  end

  test "method filter changes which origins qualify" do
    a = target!(host: "posts.only"); endpoint!(a, "/x", method: "POST")
    b = target!(host: "gets.only"); endpoint!(b, "/y", method: "GET")
    get targets_sitemap_path(methods: [ "POST" ])
    assert_match "posts.only", @response.body
    assert_no_match "gets.only", @response.body
  end

  test "program filter restricts the origin list" do
    a = target!(host: "atg.host"); a.update!(program: "atg"); endpoint!(a, "/x")
    b = target!(host: "gen.host"); b.update!(program: "gen"); endpoint!(b, "/y")
    get targets_sitemap_path(program: "atg")
    assert_match "atg.host", @response.body
    assert_no_match "gen.host", @response.body
  end

  test "tree applies the method filter to the built nodes" do
    t = target!(host: "t.host"); endpoint!(t, "/keep", method: "POST"); endpoint!(t, "/drop", method: "GET")
    get targets_sitemap_origin_tree_path(t, methods: [ "POST" ])
    assert_response :success
    assert_match "keep", @response.body
    assert_no_match(/\bdrop\b/, @response.body) # not "backdrop" (sidebar markup) — whole word only
  end

  test "filter panel renders controls and echoes active values" do
    a = target!(host: "f.host"); a.update!(program: "atg"); endpoint!(a, "/x", method: "POST")
    get targets_sitemap_path(methods: [ "POST" ], min_count: 2, program: "atg", status: [ "2" ], path: "x", has_query: "1")
    assert_response :success
    assert_select "form[action=?][method=get]", targets_sitemap_path
    assert_select "input[name='min_count'][value='2']"
    assert_select "input[name='methods[]'][value='POST'][checked]"
    assert_select "input[name='status[]'][value='2'][checked]"
    assert_select "input[name='path'][value='x']"
    assert_select "select[name='program'] option[selected][value='atg']"
    assert_select "input[name='has_query'][checked]"
  end

  test "root-only origin is hidden and root does not increment default counts" do
    root_only = target!(host: "root.only"); endpoint!(root_only, "/")
    mixed = target!(host: "mixed.host"); endpoint!(mixed, "/"); endpoint!(mixed, "/api")

    get targets_sitemap_path

    assert_no_match "root.only", response.body
    assert_select "turbo-frame#origin_tree_#{mixed.id}", count: 1
    assert_select "li[data-node]", text: /mixed\.host:443.*1/m, count: 1
  end

  test "include_root shows root-only origins and is forwarded to the tree" do
    target = target!(host: "root.only"); endpoint!(target, "/")

    get targets_sitemap_path(include_root: "1")

    assert_match "root.only", response.body
    assert_select "input[name=include_root][checked]"
    assert_select "turbo-frame#origin_tree_#{target.id}[data-src=?]",
                  targets_sitemap_origin_tree_path(target, include_root: "1")
  end

  test "root dork selects root and is forwarded to the tree" do
    target = target!(host: "root.only"); endpoint!(target, "/")

    get targets_sitemap_path(q: "root:yes")

    assert_match "root.only", response.body
    assert_select "turbo-frame#origin_tree_#{target.id}[data-src=?]",
                  targets_sitemap_origin_tree_path(target, q: "root:yes")
  end

  test "free text and endpoint dorks filter origin counts" do
    target = target!(host: "api.example.com")
    endpoint!(target, "/admin", method: "POST", status: 503)
    endpoint!(target, "/public", method: "GET", status: 200)

    get targets_sitemap_path(q: "host:api.example.com method:POST status:>=500")

    assert_match "api.example.com", response.body
    assert_select "li[data-node]", text: /api\.example\.com:443.*1/m, count: 1
  end

  test "search form preserves active sidebar filters and renders syntax help" do
    target = target!(host: "api.example.com"); endpoint!(target, "/admin", method: "POST")

    get targets_sitemap_path(methods: [ "POST" ], status: [ "2" ], include_root: "1", min_count: 2)

    assert_select "form[data-sitemap-search] input[type=hidden][name='methods[]'][value=POST]"
    assert_select "form[data-sitemap-search] input[type=hidden][name='status[]'][value='2']"
    assert_select "form[data-sitemap-search] input[type=hidden][name=include_root][value='1']"
    assert_select "button[aria-label='Search syntax help']"
    assert_match "root:yes", response.body
  end
end
