require "test_helper"

class Sitemap::TreeTest < ActiveSupport::TestCase
  Ep = Struct.new(:id, :path, :method, :status_code, :url)

  def build(*paths)
    eps = paths.each_with_index.map { |p, i| Ep.new(i + 1, p, "GET", 200, "https://ex.com:443#{p}") }
    Sitemap::Tree.build(eps)
  end

  test "a single leaf endpoint" do
    nodes = build("/about")
    assert_equal ["about"], nodes.map(&:label)
    n = nodes.first
    assert_equal "/about", n.full_path
    assert n.endpoint?
    refute n.folder?
  end

  test "nested folders with a leaf" do
    nodes = build("/_nuxt/app.js")
    folder = nodes.sole
    assert_equal "_nuxt/", folder.label
    assert folder.folder?
    refute folder.endpoint?
    leaf = folder.children.sole
    assert_equal "app.js", leaf.label
    assert_equal "/_nuxt/app.js", leaf.full_path
    assert leaf.endpoint?
  end

  test "trailing slash makes /about and /about/ distinct siblings" do
    nodes = build("/about", "/about/x")
    labels = nodes.map(&:label)
    assert_includes labels, "about"       # leaf request
    assert_includes labels, "about/"      # implied directory
    dir = nodes.find { |n| n.label == "about/" }
    assert_equal ["x"], dir.children.map(&:label)
  end

  test "a node can be both a folder and an endpoint" do
    nodes = build("/api/", "/api/users")
    api = nodes.sole
    assert_equal "api/", api.label
    assert api.folder?
    assert api.endpoint?, "/api/ is itself a request"
    assert_equal ["users"], api.children.map(&:label)
  end

  test "root request attaches to a '/' node" do
    nodes = build("/")
    assert_equal ["/"], nodes.map(&:label)
    assert nodes.first.endpoint?
  end

  test "sort: folders before leaves, each alphabetical (case-insensitive)" do
    nodes = build("/zebra", "/Alpha/x", "/beta")
    assert_equal ["Alpha/", "beta", "zebra"], nodes.map(&:label)
  end

  test "same path different method collapses to one node (lowest id wins)" do
    eps = [Ep.new(2, "/x", "POST", 201), Ep.new(1, "/x", "GET", 200)]
    node = Sitemap::Tree.build(eps).sole
    assert_equal 1, node.endpoint.id
  end

  test "empty path segments from // collapse like a single /" do
    nodes = build("/a//b")
    refute_includes nodes.map(&:label), "/", "no top-level node should be labeled '/'"
    folder = nodes.sole
    assert_equal "a/", folder.label
    assert folder.folder?
    leaf = folder.children.sole
    assert_equal "b", leaf.label
    assert_equal "/a/b", leaf.full_path
    assert leaf.endpoint?
  end

  test "methods aggregates unique upcased methods at a node" do
    eps = [Ep.new(1, "/x", "get", 200, "https://ex.com/x"),
           Ep.new(2, "/x", "post", 201, "https://ex.com/x")]
    node = Sitemap::Tree.build(eps).sole
    assert_equal ["GET", "POST"], node.methods
  end

  test "has_query? is true when any endpoint at the node has a query string" do
    eps = [Ep.new(1, "/s", "GET", 200, "https://ex.com/s"),
           Ep.new(2, "/s", "GET", 200, "https://ex.com/s?a=1")]
    node = Sitemap::Tree.build(eps).sole
    assert node.has_query?
  end

  test "has_query? false and methods present for a plain endpoint" do
    node = build("/plain").sole
    refute node.has_query?
    assert_equal ["GET"], node.methods
  end

  test "pure folder node has empty methods and no query" do
    folder = build("/dir/child").sole
    assert_equal "dir/", folder.label
    assert_equal [], folder.methods
    refute folder.has_query?
  end
end
