require "test_helper"

class Assistant::ValidationDispatcherTest < ActiveSupport::TestCase
  SOURCE = <<~YAML
    ---
    - hosts: workers
      gather_facts: false
      tasks:
        - ansible.builtin.debug:
            msg: ready
  YAML

  setup do
    @turn = assistant_turns(:created)
    @original_enabled = ENV["ASSISTANT_ENABLED"]
    ENV["ASSISTANT_ENABLED"] = "true"
    Assistant::Setting.instance.enable!
    @service_identity, = Assistant::ServiceIdentity.generate!(
      name: "validator-test-mcp", role: "mcp_reader"
    )
    Assistant::Grants::Issuer.call(
      turn: @turn, resources: [], tools: [ "validate_ansible_draft", "get_validation_result" ]
    )
    @grant = Assistant::TurnGrant.order(:id).last
    @original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
  end

  teardown do
    ENV["ASSISTANT_ENABLED"] = @original_enabled
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_allowlist
  end

  test "stores an encrypted grant-bound request before transient dispatch" do
    published = nil
    validation_id = nil
    stub_methods(Assistant::Broker, publish: ->(**attributes) { published = attributes; true }) do
      validation_id = dispatch_validation
      request = Assistant::ValidationRequest.find(validation_id)

      assert_equal @turn, request.turn
      assert_equal @grant, request.turn_grant
      assert_equal "pending", request.status
      assert_equal SOURCE, request.source
      assert_equal Digest::SHA256.hexdigest(SOURCE), request.source_digest
      assert_operator request.expires_at, :<=, @grant.expires_at
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT source FROM assistant_validation_requests WHERE id = #{ActiveRecord::Base.connection.quote(request.id)}"
      )
      refute_includes raw, "hosts"
    end

    assert_equal "assistant.validations", published.fetch(:exchange)
    assert_equal "assistant.validator.requests", published.fetch(:routing_key)
    assert_equal false, published.fetch(:persistent)
    assert_equal validation_id, published.dig(:body, "validation_id")
    assert_equal SOURCE, published.dig(:body, "source")
    refute_includes published.to_json, @grant.token_digest
  end

  test "invalid static policy creates no request and publishes nothing" do
    published = false
    ENV.delete("ASSISTANT_ANSIBLE_MODULE_ALLOWLIST")

    stub_methods(Assistant::Broker, publish: ->(**) { published = true }) do
      error = assert_raises(Assistant::ValidationDispatcher::InvalidDraft) do
        dispatch_validation
      end
      assert_includes error.result.codes, "assistant_ansible_policy_unconfigured"
    end

    refute published
    assert_equal 0, Assistant::ValidationRequest.count
  end

  test "terminal ingestion clears source and keeps only encrypted normalized result" do
    validation_id = nil
    stub_methods(Assistant::Broker, publish: true) do
      validation_id = dispatch_validation
    end

    Assistant::ValidationDispatcher.ingest!({
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "validation_id" => validation_id,
      "correlation_id" => @turn.correlation_id,
      "status" => "valid",
      "codes" => []
    })

    request = Assistant::ValidationRequest.find(validation_id)
    assert_equal "valid", request.status
    assert_nil request.source
    assert_equal SOURCE, request.result.fetch("normalized")
    row = ActiveRecord::Base.connection.select_one(
      "SELECT source, result FROM assistant_validation_requests WHERE id = #{ActiveRecord::Base.connection.quote(request.id)}"
    )
    assert_nil row.fetch("source")
    refute_includes row.fetch("result"), "hosts"
  end

  test "a second validation cannot be queued while one is pending" do
    publications = 0

    stub_methods(Assistant::Broker, publish: ->(**) { publications += 1 }) do
      dispatch_validation
      error = assert_raises(Assistant::RateLimiter::LimitExceeded) do
        dispatch_validation
      end
      assert_equal "validation_in_flight", error.code
    end

    assert_equal 1, publications
    assert_equal 1, Assistant::ValidationRequest.where(turn: @turn, status: "pending").count
  end

  test "shutdown after static validation prevents persistence and publication" do
    static = Assistant::DraftValidation::AnsibleStatic.call(SOURCE)
    published = false

    stub_methods(Assistant::DraftValidation::AnsibleStatic,
      call: lambda { |_yaml|
        Assistant::KillSwitch.disable!(user: users(:one))
        static
      }) do
      stub_methods(Assistant::Broker, publish: ->(**) { published = true }) do
        assert_raises(Assistant::ValidationDispatcher::DispatchFailed) do
          dispatch_validation
        end
      end
    end

    refute published
    assert_equal 0, Assistant::ValidationRequest.count
  end

  private

  def dispatch_validation
    Assistant::ValidationDispatcher.call(
      turn: @turn,
      grant: @grant,
      service_identity: @service_identity,
      yaml: SOURCE
    )
  end
end
