require "test_helper"

class ControlCenter::TargetSelectionTest < ActiveSupport::TestCase
  Sel = ControlCenter::TargetSelection

  test "validate! rejects an unknown source" do
    assert_raises(ControlCenter::TargetSelection::InvalidSelection) do
      Sel.validate!([{ "source" => "bogus" }])
    end
    assert Sel.validate!([{ "source" => "targets", "mode" => "filter", "q" => "x" }])
  end

  test "count sums per-source counts plus non-blank manual lines" do
    stub_methods(Targets::MongoSource,
      each_host: ->(**kw, &blk) { %w[a b].each { |h| blk.call(h) }; true },
      count_hosts: ->(**kw) { 2 }) do
      stub_methods(Sitemap::EndpointResolver,
        each_url: ->(**kw, &blk) { %w[u1].each { |u| blk.call(u) }; true },
        count_urls: ->(**kw) { 1 }) do
        count = Sel.count(
          [{ "source" => "targets", "q" => "x" }, { "source" => "sitemap", "q" => "y" }],
          ["m1", "  ", "m2"]
        )
        assert_equal 5, count # 2 hosts + 1 url + 2 manual
      end
    end
  end

  test "stream yields manual first, then sources, de-duped, and returns the unique count" do
    stub_methods(Targets::MongoSource,
      each_host: ->(**kw, &blk) { %w[dup.com b.com].each { |h| blk.call(h) }; true },
      count_hosts: ->(**kw) { 2 }) do
      stub_methods(Sitemap::EndpointResolver,
        each_url: ->(**kw, &blk) { %w[https://x/1].each { |u| blk.call(u) }; true },
        count_urls: ->(**kw) { 1 }) do
        got = []
        n = Sel.stream(
          [{ "source" => "targets", "q" => "x" }, { "source" => "sitemap", "q" => "y" }],
          ["dup.com", "m1"]
        ) { |v| got << v }
        assert_equal ["dup.com", "m1", "b.com", "https://x/1"], got
        assert_equal 4, n
      end
    end
  end

  test "stream raises ResolutionIncomplete when the targets source read is cut short" do
    stub_methods(Targets::MongoSource,
      each_host: ->(**kw, &blk) { blk.call("a.com"); false }) do
      error = assert_raises(ControlCenter::TargetSelection::ResolutionIncomplete) do
        Sel.stream([{ "source" => "targets", "q" => "x" }], []) { |v| }
      end
      assert_match(/incomplete/i, error.message)
    end
  end

  test "sample does not raise on an incomplete targets source read, returns partial results" do
    stub_methods(Targets::MongoSource,
      each_host: ->(**kw, &blk) { blk.call("a.com"); false }) do
      assert_equal ["a.com"], Sel.sample([{ "source" => "targets", "q" => "x" }], [], limit: 50)
    end
  end

  test "sample returns at most `limit` unique targets" do
    stub_methods(Targets::MongoSource,
      each_host: ->(**kw, &blk) { %w[a b c d].each { |h| blk.call(h) }; true },
      count_hosts: ->(**kw) { 4 }) do
      stub_methods(Sitemap::EndpointResolver,
        each_url: ->(**kw, &blk) { [].each { |u| blk.call(u) }; true },
        count_urls: ->(**kw) { 0 }) do
        assert_equal %w[a b], Sel.sample([{ "source" => "targets", "q" => "x" }], [], limit: 2)
      end
    end
  end
end
