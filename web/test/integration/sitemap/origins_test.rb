require "test_helper"

class Sitemap::OriginsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(User.take) }

  def target!(host:, port: 443, scheme: "https", removed_at: nil)
    now = Time.current
    Sitemap::Target.create!(origin: "#{scheme}://#{host}:#{port}", scheme: scheme, host: host,
                            port: port, first_seen_at: now, last_seen_at: now, removed_at: removed_at)
  end

  def endpoint!(target, path)
    now = Time.current
    Sitemap::Endpoint.create!(target_id: target.id, origin: target.origin, url: "#{target.origin}#{path}",
      path: path, method: "GET", url_digest: Sitemap::Origin.digest("#{target.origin}#{path}", "GET"),
      first_seen_at: now, last_seen_at: now)
  end

  test "index lists active origins ordered by host with endpoint counts" do
    a = target!(host: "www.atg.se"); endpoint!(a, "/x"); endpoint!(a, "/y")
    target!(host: "iam.atg.se")
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
    target!(host: "presse.generali.fr")
    get sitemap_root_path(q: "generali")
    assert_match "presse.generali.fr", @response.body
    assert_no_match "www.atg.se", @response.body
  end
end
