require "test_helper"

class SimpleIconsTest < ActiveSupport::TestCase
  test "looks up a plain lowercase technology name" do
    icon = SimpleIcons.lookup("php")
    assert_equal "php", icon[:slug]
    assert_equal "PHP", icon[:title]
    assert_match(/\A[0-9A-Fa-f]{6}\z/, icon[:hex])
    assert icon[:path].present?
  end

  test "normalizes case and punctuation before matching" do
    assert_equal "nginx", SimpleIcons.lookup("Nginx")[:slug]
    assert_equal "wordpress", SimpleIcons.lookup("WordPress")[:slug]
  end

  test "resolves aliases for names that do not map to a slug" do
    assert_equal "rubyonrails", SimpleIcons.lookup("Ruby on Rails")[:slug]
    assert_equal "nodedotjs", SimpleIcons.lookup("Node.js")[:slug]
    assert_equal "socketdotio", SimpleIcons.lookup("Socket.IO")[:slug]
    assert_equal "apachetomcat", SimpleIcons.lookup("Tomcat")[:slug]
    assert_equal "eclipsejetty", SimpleIcons.lookup("Jetty")[:slug]
    assert_equal "envoyproxy", SimpleIcons.lookup("Envoy")[:slug]
    assert_equal "angular", SimpleIcons.lookup("AngularJS")[:slug]
  end

  test "matches by icon title so alternate spellings resolve without an alias" do
    # Dot-less / space-variant spellings the ".js"/".io" candidate rules miss are
    # caught by the title index (grounded in each icon's real title).
    assert_equal "nodedotjs",   SimpleIcons.lookup("NodeJS")[:slug]
    assert_equal "vuedotjs",    SimpleIcons.lookup("VueJS")[:slug]
    assert_equal "socketdotio", SimpleIcons.lookup("SocketIO")[:slug]
  end

  test "strips version noise before matching" do
    assert_equal "nginx", SimpleIcons.lookup("nginx/1.18.0")[:slug]
    assert_equal "apache", SimpleIcons.lookup("Apache/2.4.41")[:slug]
    assert_equal "wordpress", SimpleIcons.lookup("WordPress 6.4")[:slug]
    assert_equal "jquery", SimpleIcons.lookup("jQuery 3.6.0")[:slug]
  end

  test "strips generic descriptor words to reach the brand" do
    assert_equal "apache", SimpleIcons.lookup("Apache HTTP Server")[:slug]
    assert_equal "cloudflare", SimpleIcons.lookup("Cloudflare Bot Management")[:slug]
  end

  test "does not truncate brands with embedded digits" do
    # "Log4j" must not be cut at the digit (no whitespace before it).
    assert_equal "log4j", SimpleIcons.normalize("Log4j")
  end

  test "returns a monogram-worthy nil for technologies with no icon" do
    # These genuinely have no Simple Icons entry; the caller renders a monogram.
    ["Varnish", "HAProxy", "Microsoft-IIS", "LiteSpeed"].each do |t|
      assert_nil SimpleIcons.lookup(t), "expected no icon for #{t}"
    end
  end

  test "returns nil for unknown or blank names" do
    assert_nil SimpleIcons.lookup("totally-not-a-real-tech-xyz")
    assert_nil SimpleIcons.lookup("")
    assert_nil SimpleIcons.lookup(nil)
  end

  test "normalize strips non-alphanumerics and downcases" do
    assert_equal "socketio", SimpleIcons.normalize("Socket.IO")
  end

  test "every ALIASES target exists in the vendored dataset" do
    SimpleIcons::ALIASES.each_value do |slug|
      assert SimpleIcons.data.key?(slug), "alias target #{slug} missing from icons.json"
    end
  end
end
