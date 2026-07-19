require "test_helper"

class Sitemap::TreeFragmentTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host: "www.atg.se")
    now = Time.current
    Sitemap::Target.create!(origin: "https://#{host}:443", scheme: "https", host: host, port: 443,
                            first_seen_at: now, last_seen_at: now)
  end

  def endpoint!(target, path)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: "GET", url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now)
  end

  test "tree renders nested folders and leaf endpoints" do
    t = target!
    endpoint!(t, "/about")
    leaf = endpoint!(t, "/_nuxt/app.js")

    get sitemap_origin_tree_path(t)
    assert_response :success
    assert_select "turbo-frame#origin_tree_#{t.id}"
    assert_match "_nuxt/", @response.body                 # folder row
    assert_match "app.js", @response.body                 # leaf row
    assert_select "button[data-url=?]", sitemap_endpoint_path(leaf.id)   # leaf loads detail
    assert_select "button[data-action*='sitemap-tree#activate']"

    leaf_url = sitemap_endpoint_path(leaf.id)
    leaf_button = css_select(%(button[data-url="#{leaf_url}"])).first
    assert_includes leaf_button["class"], "data-[selected]:bg-zinc-200", "selected-row style must be self-contained via Tailwind data-attribute variant"

    assert_select "button[aria-expanded='false']" # folder toggle exposes expanded state
    refute_includes leaf_button.attributes.keys, "aria-expanded", "leaf/endpoint buttons must not carry aria-expanded"
  end

  test "empty state when the origin has no active endpoints" do
    t = target!
    get sitemap_origin_tree_path(t)
    assert_response :success
    assert_match(/no endpoints/i, @response.body)
  end

  test "tombstoned endpoints are excluded" do
    t = target!
    e = endpoint!(t, "/gone"); e.update!(removed_at: Time.current)
    get sitemap_origin_tree_path(t)
    assert_no_match "gone", @response.body
  end

  test "missing target is 404" do
    get sitemap_origin_tree_path(id: 999_999)
    assert_response :not_found
  end
end
