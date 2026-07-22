require "test_helper"

class Sitemap::TreeFragmentTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host: "www.atg.se")
    now = Time.current
    Sitemap::Target.create!(origin: "https://#{host}:443", scheme: "https", host: host, port: 443,
                            first_seen_at: now, last_seen_at: now)
  end

  def endpoint!(target, path, method: "GET")
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: method, url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", method),
      first_seen_at: now, last_seen_at: now)
  end

  test "tree renders nested folders and leaf endpoints" do
    t = target!
    endpoint!(t, "/about")
    leaf = endpoint!(t, "/_nuxt/app.js")

    get targets_sitemap_origin_tree_path(t)
    assert_response :success
    assert_select "turbo-frame#origin_tree_#{t.id}"
    assert_match "_nuxt/", @response.body                 # folder row
    assert_match "app.js", @response.body                 # leaf row
    assert_select "button[data-url=?]", targets_sitemap_endpoint_path(leaf.id)   # leaf loads detail
    assert_select "button[data-action*='sitemap-tree#activate']"

    leaf_url = targets_sitemap_endpoint_path(leaf.id)
    leaf_button = css_select(%(button[data-url="#{leaf_url}"])).first
    assert_includes leaf_button["class"], "data-[selected]:bg-zinc-200", "selected-row style must be self-contained via Tailwind data-attribute variant"

    assert_select "button[aria-expanded='false']" # folder toggle exposes expanded state
    refute_includes leaf_button.attributes.keys, "aria-expanded", "leaf/endpoint buttons must not carry aria-expanded"
  end

  test "empty state when the origin has no active endpoints" do
    t = target!
    get targets_sitemap_origin_tree_path(t)
    assert_response :success
    assert_match(/no endpoints/i, @response.body)
  end

  test "tombstoned endpoints are excluded" do
    t = target!
    e = endpoint!(t, "/gone"); e.update!(removed_at: Time.current)
    get targets_sitemap_origin_tree_path(t)
    assert_no_match "gone", @response.body
  end

  test "missing target is 404" do
    get targets_sitemap_origin_tree_path(id: 999_999)
    assert_response :not_found
  end

  test "tree uses SVG icons, elbow subtree, method chip on non-GET, red on query" do
    t = target!(host: "vis.host")
    endpoint!(t, "/nuxt/app.js")                     # nested -> folder + leaf
    endpoint!(t, "/submit", method: "POST")          # non-GET -> chip
    now = Time.current
    Sitemap::Endpoint.create!(target_id: t.id, origin: t.origin, url: "#{t.origin}/s?a=1", path: "/s",
      method: "GET", url_digest: Sitemap::Origin.digest("#{t.origin}/s?a=1", "GET"),
      first_seen_at: now, last_seen_at: now)         # parameterized -> red

    get targets_sitemap_origin_tree_path(t)
    assert_response :success
    assert_select "ul.sitemap-subtree"                       # elbow container
    assert_select "svg", minimum: 1                          # SVG icons present
    assert_no_match(/📁|📄|▸/, @response.body)               # no emojis
    assert_match "POST", @response.body                      # non-GET method chip
    assert_match "text-red-600", @response.body               # parameterized label styled red
  end

  test "root endpoint is hidden by default" do
    t = target!(host: "root.host")
    endpoint!(t, "/")
    endpoint!(t, "/child")

    get targets_sitemap_origin_tree_path(t)

    assert_select "button span", text: "/", count: 0
    assert_select "button span", text: "child", count: 1
  end

  test "include_root shows the root endpoint" do
    t = target!(host: "root.host")
    endpoint!(t, "/")

    get targets_sitemap_origin_tree_path(t, include_root: "1")

    assert_select "button span", text: "/", count: 1
  end

  test "root dork shows only the root endpoint" do
    t = target!(host: "root.host")
    endpoint!(t, "/")
    endpoint!(t, "/child")

    get targets_sitemap_origin_tree_path(t, q: "root:yes")

    assert_select "button span", text: "/", count: 1
    assert_select "button span", text: "child", count: 0
  end
end
