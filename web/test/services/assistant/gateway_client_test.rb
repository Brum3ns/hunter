require "minitest/autorun"
require_relative "../../../config/environment"
require "socket"

# Standalone: this environment has no reachable Postgres, so `test_helper`
# (which calls `fixtures :all`) cannot be loaded. GatewayClient is pure HTTP
# and needs none of that — boot Rails directly and drive it against a real
# in-process TCP server so the test exercises actual socket behaviour
# (headers, timeouts, oversize bodies) instead of only asserting on stubbed
# call arguments.
class Assistant::GatewayClientTest < Minitest::Test
  # A minimal raw HTTP/1.1 server: accepts exactly one connection, records
  # the request, and writes back whatever raw bytes the handler returns (or
  # nothing at all, to simulate a stalled/never-responding peer).
  class FakeServer
    attr_reader :last_request

    def initialize
      @tcp = TCPServer.new("127.0.0.1", 0)
    end

    def url
      "http://127.0.0.1:#{@tcp.addr[1]}"
    end

    def serve_once(&handler)
      @thread = Thread.new do
        socket = @tcp.accept
        begin
          request_line = socket.gets
          headers = {}
          while (line = socket.gets) && !line.match?(/\A\r?\n\z/)
            key, value = line.split(":", 2)
            headers[key.strip] = value.strip if key && value
          end
          length = headers["Content-Length"].to_i
          body = length.positive? ? socket.read(length) : ""
          @last_request = { request_line: request_line.to_s.strip, headers: headers, body: body }
          raw = handler.call(@last_request)
          socket.write(raw) if raw
        rescue IOError, Errno::EPIPE, Errno::ECONNRESET
          nil
        ensure
          socket.close
        end
      end
    end

    def close
      @tcp.close
    end
  end

  def setup
    @server = FakeServer.new
  end

  def teardown
    @server.close
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def stub_methods(target, mapping)
    originals = mapping.keys.index_with { |name| target.method(name) }
    mapping.each do |name, impl|
      target.define_singleton_method(name) do |*args, **kwargs, &blk|
        impl.respond_to?(:call) ? impl.call(*args, **kwargs, &blk) : impl
      end
    end
    yield
  ensure
    originals.each { |name, method| target.define_singleton_method(name, method) }
  end

  def http_response(status:, body:)
    "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
  end

  def run_against(gateway_url:, token: "test-ingress-token")
    with_env("ASSISTANT_GATEWAY_URL" => gateway_url, "ASSISTANT_GATEWAY_INGRESS_TOKEN" => token) do
      yield
    end
  end

  def capture_error
    yield
    flunk "expected Assistant::GatewayClient::Error to be raised"
  rescue Assistant::GatewayClient::Error => error
    error
  end

  def test_posts_the_envelope_to_slash_turns_with_the_bearer_token
    events_body = JSON.generate(
      "schema_version" => 1, "correlation_id" => "c-1",
      "events" => [ { "kind" => "assistant_message", "data" => { "body" => "hi" } } ]
    )
    @server.serve_once { http_response(status: "200 OK", body: events_body) }

    events = run_against(gateway_url: @server.url, token: "secret-123") do
      Assistant::GatewayClient.run_turn({ "schema_version" => 1, "correlation_id" => "c-1" })
    end

    assert_equal [ { "kind" => "assistant_message", "data" => { "body" => "hi" } } ], events
    request = @server.last_request
    assert_equal "POST /turns HTTP/1.1", request[:request_line]
    assert_equal "Bearer secret-123", request[:headers]["Authorization"]
    assert_equal "application/json", request[:headers]["Content-Type"]
    assert_equal({ "schema_version" => 1, "correlation_id" => "c-1" }, JSON.parse(request[:body]))
  end

  def test_error_envelope_raises_with_code_preserved
    body = JSON.generate("error" => { "code" => "gateway_saturated" })
    @server.serve_once { http_response(status: "503 Service Unavailable", body: body) }

    error = run_against(gateway_url: @server.url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
    assert_kind_of Assistant::GatewayClient::Error, error
    assert_equal "gateway_saturated", error.code
  end

  def test_connection_failure_becomes_an_error_code_not_an_exception
    dead = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{dead.addr[1]}"
    dead.close # nothing listens on this port anymore

    error = run_against(gateway_url: url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
    assert_kind_of Assistant::GatewayClient::Error, error
    # Distinguished from a DNS failure and from a mid-request disconnect: all three
    # used to report "gateway_unreachable", which made a gateway that was never
    # listening indistinguishable from one that was up and dropping the request.
    assert_equal "gateway_connection_refused", error.code
  end

  def test_timeout_becomes_gateway_timeout
    @server.serve_once do |_request|
      sleep 0.5
      nil # never actually respond
    end

    stub_methods(Assistant::GatewayClient, open_timeout_seconds: 0.2, read_timeout_seconds: 0.2) do
      error = run_against(gateway_url: @server.url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
      assert_equal "gateway_timeout", error.code
    end
  end

  def test_oversize_response_is_rejected_before_parsing
    oversize = JSON.generate("schema_version" => 1, "events" => [ { "pad" => "x" * (Assistant::GatewayClient::MAX_RESPONSE_BYTES + 1) } ])
    @server.serve_once { http_response(status: "200 OK", body: oversize) }

    error = run_against(gateway_url: @server.url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
    assert_equal "gateway_response_too_large", error.code
  end

  def test_malformed_non_json_body_is_handled
    @server.serve_once { http_response(status: "200 OK", body: "this is not json") }

    error = run_against(gateway_url: @server.url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
    assert_equal "gateway_malformed_response", error.code
  end

  def test_schema_version_other_than_1_is_rejected
    body = JSON.generate("schema_version" => 2, "events" => [])
    @server.serve_once { http_response(status: "200 OK", body: body) }

    error = run_against(gateway_url: @server.url) { capture_error { Assistant::GatewayClient.run_turn({}) } }
    assert_equal "invalid_response", error.code
  end

  # Mutation check (manual, documented in the task report): temporarily
  # changing `run_turn`'s condition from `== 1` to `== 2` makes this test
  # fail, and reverting `MAX_RESPONSE_BYTES` enforcement makes the oversize
  # test fail — see task-5-report.md.

  # ENV.fetch on a missing ingress token would otherwise raise KeyError straight
  # out of run_turn, stranding the turn instead of failing it observably.
  def test_a_missing_ingress_token_becomes_an_error_code
    previous = ENV["ASSISTANT_GATEWAY_INGRESS_TOKEN"]
    ENV.delete("ASSISTANT_GATEWAY_INGRESS_TOKEN")

    error = assert_raises(Assistant::GatewayClient::Error) do
      Assistant::GatewayClient.run_turn({ "schema_version" => 1 })
    end
    assert_equal "gateway_token_missing", error.code
  ensure
    previous.nil? ? ENV.delete("ASSISTANT_GATEWAY_INGRESS_TOKEN") : ENV["ASSISTANT_GATEWAY_INGRESS_TOKEN"] = previous
  end


  def test_an_unresolvable_host_is_reported_as_a_dns_failure
    error = run_against(gateway_url: "http://assistant-gateway-does-not-exist.invalid:8081") do
      capture_error { Assistant::GatewayClient.run_turn({}) }
    end
    assert_kind_of Assistant::GatewayClient::Error, error
    assert_equal "gateway_dns_failure", error.code
  end

  # A gateway that accepts the connection and then drops it without replying is up
  # but failing the turn -- a different fault from not listening at all.
  def test_a_dropped_connection_is_reported_as_a_closed_connection
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    accepter = Thread.new do
      socket = server.accept
      socket.close # accept, then hang up without responding
    rescue IOError
      nil
    end

    error = run_against(gateway_url: "http://127.0.0.1:#{port}") do
      capture_error { Assistant::GatewayClient.run_turn({}) }
    end

    assert_kind_of Assistant::GatewayClient::Error, error
    assert_equal "gateway_closed_connection", error.code
  ensure
    accepter&.kill
    server&.close
  end

end
