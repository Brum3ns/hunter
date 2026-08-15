require "minitest/autorun"
require "socket"
require_relative "../../../config/environment"

# Standalone: no reachable Postgres here, and none needed -- Preflight touches no
# ActiveRecord. The prober and sleeper are injected so nothing opens a socket.
class Assistant::PreflightTest < Minitest::Test
  # Serves exactly one HTTP request on a loopback port with the given status
  # line and no body, then closes. Used to exercise the REAL `probe` method
  # against the status codes the Go /healthz handlers actually return, which the
  # injected-prober tests above never touch.
  def with_status_server(status_line)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      while (line = client.gets) && line != "\r\n"; end # drain request head to the blank line
      client.write("HTTP/1.1 #{status_line}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      client.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}/healthz"
  ensure
    thread&.join(2)
    server&.close
  end
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
    assert(urls.any? { |url| url.include?("assistant-codex") })
    assert(urls.any? { |url| url.include?("assistant-claude") })
    refute(urls.any? { |url| url.include?("assistant-gateway") })
    refute(urls.any? { |url| url.include?("assistant-validator") })
  end

  # /healthz needs no bearer token, so reachability is reported independently of
  # whether the ingress secret is correct.
  def test_the_probe_url_carries_no_token
    urls = []
    with_env(
      "ASSISTANT_CODEX_INGRESS_TOKEN" => "codex-super-secret-token",
      "ASSISTANT_CLAUDE_INGRESS_TOKEN" => "claude-super-secret-token"
    ) do
      Assistant::Preflight.call(prober: ->(url) { urls << url; [ true, "healthy" ] }, sleeper: ->(_s) {})
    end
    refute(urls.any? { |url| url.include?("codex-super-secret-token") })
    refute(urls.any? { |url| url.include?("claude-super-secret-token") })
  end

  def test_a_healthy_service_is_reported_ok
    checks = Assistant::Preflight.call(prober: ->(_url) { [ true, "healthy" ] }, sleeper: ->(_s) {})
    assert checks.all?(&:ok)
    assert_equal [ "assistant-claude", "assistant-codex" ], checks.map(&:service).sort
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

  # The Go /healthz handlers (gateway main.go, validator main.go) answer a ready
  # service with 204 No Content, NOT 200 -- their Docker healthchecks assert
  # exactly StatusNoContent. `probe` must therefore treat 204 as healthy, or the
  # reachability report db:seed prints declares a perfectly healthy gateway and
  # validator UNREACHABLE on every `docker compose up`.
  def test_probe_treats_a_204_from_the_go_health_endpoints_as_healthy
    with_status_server("204 No Content") do |url|
      ok, detail = Assistant::Preflight.send(:probe, url)
      assert ok, "204 (the real ready signal) reported not-ok: #{detail.inspect}"
    end
  end

  # A not-ready gateway (no usable provider credential) answers 503; that must
  # read as not-ok with the documented detail, not as an unexpected code.
  def test_probe_treats_a_503_as_not_ready
    with_status_server("503 Service Unavailable") do |url|
      ok, detail = Assistant::Preflight.send(:probe, url)
      refute ok
      assert_includes detail, "not ready"
    end
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
