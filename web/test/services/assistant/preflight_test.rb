require "minitest/autorun"
require_relative "../../../config/environment"

# Standalone: no reachable Postgres here, and none needed -- Preflight touches no
# ActiveRecord. The prober and sleeper are injected so nothing opens a socket.
class Assistant::PreflightTest < Minitest::Test
  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def test_it_probes_healthz_on_both_services
    urls = []
    Assistant::Preflight.call(prober: ->(url) { urls << url; [ true, "healthy" ] }, sleeper: ->(_s) {})

    assert_equal 2, urls.length
    assert urls.all? { |url| url.end_with?("/healthz") }, "probed #{urls.inspect}"
    assert(urls.any? { |url| url.include?("assistant-gateway") })
    assert(urls.any? { |url| url.include?("assistant-validator") })
  end

  # /healthz needs no bearer token, so reachability is reported independently of
  # whether the ingress secret is correct.
  def test_the_probe_url_carries_no_token
    urls = []
    with_env("ASSISTANT_GATEWAY_INGRESS_TOKEN" => "super-secret-token") do
      Assistant::Preflight.call(prober: ->(url) { urls << url; [ true, "healthy" ] }, sleeper: ->(_s) {})
    end
    refute(urls.any? { |url| url.include?("super-secret-token") })
  end

  def test_a_healthy_service_is_reported_ok
    checks = Assistant::Preflight.call(prober: ->(_url) { [ true, "healthy" ] }, sleeper: ->(_s) {})
    assert checks.all?(&:ok)
    assert_equal [ "assistant-gateway", "assistant-validator" ], checks.map(&:service).sort
  end

  def test_a_failing_service_is_reported_with_its_detail
    checks = Assistant::Preflight.call(
      prober: ->(_url) { [ false, "connection refused" ] }, sleeper: ->(_s) {}
    )
    refute checks.any?(&:ok)
    assert checks.all? { |check| check.detail == "connection refused" }
  end

  # The gateway and validator boot in parallel with web and have no depends_on, so
  # a single probe would race them.
  def test_it_retries_until_the_service_comes_up
    attempts = 0
    slept = 0
    checks = Assistant::Preflight.call(
      prober: lambda { |_url|
        attempts += 1
        attempts >= 3 ? [ true, "healthy" ] : [ false, "connection refused" ]
      },
      sleeper: ->(_s) { slept += 1 }
    )

    assert checks.first.ok, "gave up before the service came up"
    assert_operator slept, :>=, 1, "did not wait between attempts"
  end

  def test_it_gives_up_after_a_bounded_number_of_attempts
    attempts = 0
    Assistant::Preflight.call(prober: ->(_url) { attempts += 1; [ false, "refused" ] }, sleeper: ->(_s) {})

    # Two services, ATTEMPTS each -- bounded, so a dead service cannot hang boot.
    assert_equal Assistant::Preflight::ATTEMPTS * 2, attempts
  end

  # Compose runs `db:seed && foreman start`. A raise here would stop the web server
  # from booting, so an unreachable gateway must never propagate an exception.
  def test_a_raising_prober_never_escapes
    assert_raises(RuntimeError) { raise "control: assert_raises works here" }

    checks = nil
    begin
      checks = Assistant::Preflight.call(
        prober: ->(_url) { raise Errno::ECONNREFUSED, "boom" }, sleeper: ->(_s) {}
      )
    rescue StandardError => error
      flunk "Preflight let #{error.class} escape; this would abort db:seed and stop web booting"
    end
    refute checks.any?(&:ok)
  end
end
