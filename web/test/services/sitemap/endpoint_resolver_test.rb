require "test_helper"

class Sitemap::EndpointResolverTest < ActiveSupport::TestCase
  def endpoint(url, **over)
    Sitemap::Endpoint.create!({
      origin: "https://example.com", url: url, path: URI(url).path.presence || "/",
      method: "GET", url_digest: Digest::SHA256.digest("GET\0#{url}"),
      first_seen_at: Time.current, last_seen_at: Time.current
    }.merge(over))
  end

  test "each_url yields the url of every active endpoint" do
    endpoint("https://example.com/a")
    endpoint("https://example.com/b")
    urls = []
    Sitemap::EndpointResolver.each_url { |u| urls << u }
    assert_equal %w[https://example.com/a https://example.com/b].sort, urls.sort
  end

  test "each_url without a block returns an Enumerator" do
    endpoint("https://example.com/c")
    assert_kind_of Enumerator, Sitemap::EndpointResolver.each_url
    assert_equal %w[https://example.com/c], Sitemap::EndpointResolver.each_url.to_a
  end

  test "ids restrict to the listed rows; exclude_ids remove them" do
    a = endpoint("https://example.com/a")
    b = endpoint("https://example.com/b")
    assert_equal [a.url], Sitemap::EndpointResolver.each_url(ids: [a.id]).to_a
    assert_equal [b.url], Sitemap::EndpointResolver.each_url(exclude_ids: [a.id]).to_a
  end

  test "count_urls counts matching rows" do
    endpoint("https://example.com/a")
    endpoint("https://example.com/b")
    assert_equal 2, Sitemap::EndpointResolver.count_urls
  end

  test "tombstoned (removed_at) endpoints are excluded" do
    endpoint("https://example.com/gone", removed_at: Time.current)
    assert_equal 0, Sitemap::EndpointResolver.count_urls
  end
end
