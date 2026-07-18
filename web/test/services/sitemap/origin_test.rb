require "test_helper"

module Sitemap
  class OriginTest < ActiveSupport::TestCase
    test "build fills implicit ports and lowercases" do
      assert_equal "https://ex.com:443", Sitemap::Origin.build(scheme: "HTTPS", host: "Ex.com")
      assert_equal "http://ex.com:80",   Sitemap::Origin.build(scheme: "http", host: "ex.com")
      assert_equal "http://ex.com:8080", Sitemap::Origin.build(scheme: "http", host: "ex.com", port: 8080)
    end

    test "build returns nil without a host" do
      assert_nil Sitemap::Origin.build(scheme: "http", host: "")
    end

    test "parse extracts origin, path, and normalized url" do
      r = Sitemap::Origin.parse("HTTPS://Ex.com/Login?a=1#frag")
      assert_equal "https://ex.com:443", r[:origin]
      assert_equal "/Login", r[:path]
      assert_equal "https://ex.com:443/Login?a=1", r[:url]
      assert_equal 443, r[:port]
    end

    test "parse defaults an empty path to slash and rejects non-http" do
      assert_equal "/", Sitemap::Origin.parse("http://ex.com")[:path]
      assert_nil Sitemap::Origin.parse("ftp://ex.com/x")
      assert_nil Sitemap::Origin.parse("not a url")
    end

    test "digest is stable and method-sensitive" do
      a = Sitemap::Origin.digest("https://ex.com:443/x", "get")
      b = Sitemap::Origin.digest("https://ex.com:443/x", "GET")
      c = Sitemap::Origin.digest("https://ex.com:443/x", "POST")
      assert_equal a, b
      assert_equal 32, a.bytesize
      refute_equal a, c
    end
  end
end
