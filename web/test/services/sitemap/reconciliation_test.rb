require "test_helper"

class Sitemap::ReconciliationTest < ActiveSupport::TestCase
  def alive(host) = { "_id" => "a-#{host}", "target" => { "scheme" => "https", "host" => host, "port" => 443 }, "metadata" => { "program" => "acme" } }
  def katana(url) = { "_id" => "k-#{url.hash}", "request" => { "endpoint" => url, "method" => "GET" }, "response" => { "status_code" => 200 } }

  def stub_mongo(alive: [], katana: [], wayback: [])
    stub_methods(Sitemap::MongoSource,
      each_alive:   ->(&b) { alive.each(&b) },
      each_katana:  ->(&b) { katana.each(&b) },
      each_wayback: ->(&b) { wayback.each(&b) }) { yield }
  end

  test "first run materializes matched endpoints" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) do
      stats = Sitemap::Reconciliation.new.run
      assert_equal 1, Sitemap::Target.active.count
      ep = Sitemap::Endpoint.active.sole
      assert_equal "https://ex.com:443", ep.target.origin
      assert_equal 1, stats[:endpoints_upserted]
    end
  end

  test "a URL gone on the next run is tombstoned, and reappearance revives it" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    stub_mongo(alive: [alive("ex.com")], katana: []) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.removed_at.present?
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert_nil Sitemap::Endpoint.sole.removed_at
  end

  test "endpoint seen before its target attaches once the asset appears" do
    stub_mongo(alive: [], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.target_id.nil?
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.target_id.present?
  end

  test "an incomplete katana scan does not tombstone previously-materialized endpoints" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Endpoint.sole.removed_at.nil?

    stub_methods(Sitemap::MongoSource,
      each_alive:   ->(&b) { [alive("ex.com")].each(&b); true },
      each_katana:  ->(&b) { false },
      each_wayback: ->(&b) { [].each(&b); true }) do
      stats = Sitemap::Reconciliation.new.run
      assert_equal 0, stats[:endpoints_tombstoned]
    end

    assert_nil Sitemap::Endpoint.sole.removed_at, "endpoint must not be tombstoned when the katana scan failed"
  end

  test "an incomplete alive scan does not tombstone previously-materialized targets" do
    stub_mongo(alive: [alive("ex.com")], katana: [katana("https://ex.com/a")]) { Sitemap::Reconciliation.new.run }
    assert Sitemap::Target.sole.removed_at.nil?

    stub_methods(Sitemap::MongoSource,
      each_alive:   ->(&b) { false },
      each_katana:  ->(&b) { [katana("https://ex.com/a")].each(&b); true },
      each_wayback: ->(&b) { [].each(&b); true }) do
      stats = Sitemap::Reconciliation.new.run
      assert_equal 0, stats[:targets_tombstoned]
    end

    assert_nil Sitemap::Target.sole.removed_at, "target must not be tombstoned when the alive scan failed"
  end
end
