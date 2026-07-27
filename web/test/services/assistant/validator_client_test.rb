require "minitest/autorun"
require_relative "../../../config/environment"
require "socket"

# Standalone for the same reason as gateway_client_test.rb: no Postgres here,
# so `test_helper` (fixtures :all) is unusable, and ValidatorClient is pure
# HTTP anyway. Driven against a real in-process TCP server rather than
# stubbed call arguments, mirroring the gateway client's test.
class Assistant::ValidatorClientTest < Minitest::Test
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

  def run_against(validator_url:, token: "test-ingress-token")
    with_env("ASSISTANT_VALIDATOR_URL" => validator_url, "ASSISTANT_VALIDATOR_INGRESS_TOKEN" => token) do
      yield
    end
  end

  def capture_error
    yield
    flunk "expected Assistant::ValidatorClient::Error to be raised"
  rescue Assistant::ValidatorClient::Error => error
    error
  end

  def test_posts_the_envelope_to_slash_validations_with_the_bearer_token
    event = { "schema_version" => 1, "event_id" => "e-1", "validation_id" => "v-1",
              "correlation_id" => "c-1", "status" => "valid", "codes" => [] }
    body = JSON.generate("schema_version" => 1, "event" => event)
    @server.serve_once { http_response(status: "200 OK", body: body) }

    result = run_against(validator_url: @server.url, token: "secret-456") do
      Assistant::ValidatorClient.validate({ "schema_version" => 1, "validation_id" => "v-1" })
    end

    assert_equal event, result
    request = @server.last_request
    assert_equal "POST /validations HTTP/1.1", request[:request_line]
    assert_equal "Bearer secret-456", request[:headers]["Authorization"]
    assert_equal({ "schema_version" => 1, "validation_id" => "v-1" }, JSON.parse(request[:body]))
  end

  def test_error_envelope_raises_with_the_validator_specific_code_preserved
    body = JSON.generate("error" => { "code" => "validator_saturated" })
    @server.serve_once { http_response(status: "503 Service Unavailable", body: body) }

    error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "validator_saturated", error.code
  end

  def test_connection_failure_becomes_an_error_code_not_an_exception
    dead = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{dead.addr[1]}"
    dead.close

    error = run_against(validator_url: url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "validator_unreachable", error.code
  end

  def test_timeout_becomes_validator_timeout
    @server.serve_once do |_request|
      sleep 0.5
      nil
    end

    stub_methods(Assistant::ValidatorClient, open_timeout_seconds: 0.2, read_timeout_seconds: 0.2) do
      error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
      assert_equal "validator_timeout", error.code
    end
  end

  def test_oversize_response_is_rejected_before_parsing
    oversize = JSON.generate(
      "schema_version" => 1,
      "event" => { "pad" => "x" * (Assistant::GatewayClient::MAX_RESPONSE_BYTES + 1) }
    )
    @server.serve_once { http_response(status: "200 OK", body: oversize) }

    error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "validator_response_too_large", error.code
  end

  def test_malformed_non_json_body_is_handled
    @server.serve_once { http_response(status: "200 OK", body: "this is not json") }

    error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "validator_malformed_response", error.code
  end

  def test_schema_version_other_than_1_is_rejected
    body = JSON.generate("schema_version" => 2, "event" => {})
    @server.serve_once { http_response(status: "200 OK", body: body) }

    error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "invalid_response", error.code
  end

  def test_event_that_is_not_a_hash_is_rejected
    body = JSON.generate("schema_version" => 1, "event" => "not-a-hash")
    @server.serve_once { http_response(status: "200 OK", body: body) }

    error = run_against(validator_url: @server.url) { capture_error { Assistant::ValidatorClient.validate({}) } }
    assert_equal "invalid_response", error.code
  end
end
