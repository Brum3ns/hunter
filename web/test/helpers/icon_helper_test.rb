require "test_helper"

class IconHelperTest < ActionView::TestCase
  include IconHelper

  test "renders an svg with the requested classes" do
    html = heroicon("bell", classes: "h-5 w-5 text-indigo-500")
    assert_includes html, "<svg"
    assert_includes html, "h-5 w-5 text-indigo-500"
    assert_includes html, "stroke=\"currentColor\""
    assert html.html_safe?
  end

  test "renders multi-path icons like cog" do
    html = heroicon("cog")
    assert_equal 2, html.scan("<path").length
  end

  test "raises for an unknown icon" do
    assert_raises(ArgumentError) { heroicon("nope") }
  end

  test "renders the target department glyph" do
    assert_match(/<svg/, heroicon("target"))
  end

  test "renders new program-page glyphs" do
    %w[magnifying-glass star squares-2x2 list-bullet arrow-up arrow-down
       trash clock arrow-top-right-on-square arrow-down-tray clipboard].each do |name|
      assert_match(/<svg/, heroicon(name), "expected #{name} to render")
    end
  end
end
