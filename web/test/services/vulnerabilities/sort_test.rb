require "test_helper"

class Vulnerabilities::SortTest < ActiveSupport::TestCase
  S = Vulnerabilities::Sort

  def vuln(sev, date, name = "x")
    Vulnerability.new("finding" => { "severity" => sev, "name" => name }, "metadata" => { "date" => date }, "id" => name)
  end

  test "default key and direction" do
    assert_equal "date", S::DEFAULT_KEY
    assert_equal "desc", S.resolve_dir("date", nil)
  end

  test "unknown direction falls back to the key default" do
    assert_equal "asc", S.resolve_dir("name", "sideways")
    assert_equal "asc", S.resolve_dir("name", nil)
  end

  test "mongo_doc maps date desc with a stable tiebreaker" do
    assert_equal({ "metadata.date" => -1, "_id" => -1 }, S.mongo_doc("date", "desc"))
  end

  test "severity comparator orders critical before info regardless of direction default" do
    list = [vuln("info", "2026-01-01", "a"), vuln("critical", "2026-01-01", "b")]
    sorted = list.sort(&S.comparator("severity", S.resolve_dir("severity", nil)))
    assert_equal ["b", "a"], sorted.map(&:id)
  end

  test "date comparator desc puts newer first" do
    list = [vuln("low", "2026-01-01", "old"), vuln("low", "2026-06-01", "new")]
    sorted = list.sort(&S.comparator("date", "desc"))
    assert_equal ["new", "old"], sorted.map(&:id)
  end
end
