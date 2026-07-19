require "test_helper"

class Sitemap::TreeTest < ActiveSupport::TestCase
  Ep = Struct.new(:id, :path, :method, :status_code)

  def build(*paths)
    eps = paths.each_with_index.map { |p, i| Ep.new(i + 1, p, "GET", 200) }
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
end
