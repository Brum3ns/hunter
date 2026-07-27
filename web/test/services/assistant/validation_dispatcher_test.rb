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
    # Activation is now derived from provider credential environment variables,
    # not this env var, so stub Config.enabled? directly to simulate an installed key.
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
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
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_allowlist
  end

  test "stores an encrypted grant-bound request, then calls the validator after commit" do
    validated_envelope = nil
    validation_id = nil

    stub_methods(Assistant::ValidatorClient, validate: lambda { |envelope|
      validated_envelope = envelope
      request = Assistant::ValidationRequest.find(envelope.fetch("validation_id"))

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

      terminal_event(envelope)
    }) do
      validation_id = dispatch_validation
    end

    assert_equal validation_id, validated_envelope.fetch("validation_id")
    assert_equal SOURCE, validated_envelope.fetch("source")
    refute_includes validated_envelope.to_json, @grant.token_digest

    request = Assistant::ValidationRequest.find(validation_id)
    assert_equal "valid", request.status
    assert_nil request.source
  end

  # F10: a synchronous HTTP round trip must never run while the dispatch
  # transaction's four row locks (Setting, ServiceIdentity, Turn, TurnGrant)
  # are still held — that transaction commits, and only then is the
  # validator called. `open_transactions` here is not the test's own
  # transactional-fixtures wrapper (constant for the whole test); it is the
  # EXTRA nesting level that `call`'s own `Assistant::ValidationRequest.transaction`
  # would add if the validator call were made from inside it.
  test "the validator call happens after the dispatch transaction commits, not while locks are held" do
    baseline_depth = ActiveRecord::Base.connection.open_transactions
    observed_depth = nil

    stub_methods(Assistant::ValidatorClient, validate: lambda { |envelope|
      observed_depth = ActiveRecord::Base.connection.open_transactions
      terminal_event(envelope)
    }) do
      dispatch_validation
    end

    assert_equal baseline_depth, observed_depth
  end

  test "invalid static policy creates no request and never calls the validator" do
    validated = false
    ENV.delete("ASSISTANT_ANSIBLE_MODULE_ALLOWLIST")

    stub_methods(Assistant::ValidatorClient, validate: ->(*) { validated = true }) do
      error = assert_raises(Assistant::ValidationDispatcher::InvalidDraft) do
        dispatch_validation
      end
      assert_includes error.result.codes, "assistant_ansible_policy_unconfigured"
    end

    refute validated
    assert_equal 0, Assistant::ValidationRequest.count
  end

  test "ingest! on a terminal event clears source and keeps only the encrypted normalized result" do
    request = Assistant::ValidationRequest.create!(
      turn: @turn, turn_grant: @grant, status: "pending",
      source: SOURCE, expires_at: 5.minutes.from_now
    )

    Assistant::ValidationDispatcher.ingest!({
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "validation_id" => request.id,
      "correlation_id" => @turn.correlation_id,
      "status" => "valid",
      "codes" => []
    })

    request.reload
    assert_equal "valid", request.status
    assert_nil request.source
    assert_equal SOURCE, request.result.fetch("normalized")
    row = ActiveRecord::Base.connection.select_one(
      "SELECT source, result FROM assistant_validation_requests WHERE id = #{ActiveRecord::Base.connection.quote(request.id)}"
    )
    assert_nil row.fetch("source")
    refute_includes row.fetch("result"), "hosts"
  end

  # The old async model queued a second request while the first sat
  # "pending" awaiting an out-of-band completion event. The synchronous
  # model's equivalent "in flight" window is the validator round trip
  # itself: a second dispatch attempted WHILE the first request's validator
  # call has not yet returned must still be rejected.
  test "a second validation cannot be dispatched while the first is still in flight" do
    validations = 0

    stub_methods(Assistant::ValidatorClient, validate: lambda { |envelope|
      validations += 1
      if validations == 1
        error = assert_raises(Assistant::RateLimiter::LimitExceeded) { dispatch_validation }
        assert_equal "validation_in_flight", error.code
      end
      terminal_event(envelope)
    }) do
      dispatch_validation
    end

    assert_equal 1, validations
    assert_equal 1, Assistant::ValidationRequest.where(turn: @turn).count
  end

  test "shutdown after static validation prevents persistence and never calls the validator" do
    static = Assistant::DraftValidation::AnsibleStatic.call(SOURCE)
    validated = false

    stub_methods(Assistant::DraftValidation::AnsibleStatic,
      call: lambda { |_yaml|
        Assistant::KillSwitch.disable!(user: users(:one))
        static
      }) do
      stub_methods(Assistant::ValidatorClient, validate: ->(*) { validated = true }) do
        assert_raises(Assistant::ValidationDispatcher::DispatchFailed) do
          dispatch_validation
        end
      end
    end

    refute validated
    assert_equal 0, Assistant::ValidationRequest.count
  end

  test "a validator failure marks the request failed and raises DispatchFailed" do
    stub_methods(Assistant::ValidatorClient,
      validate: ->(*) { raise Assistant::ValidatorClient::Error, "validator_unreachable" }) do
      assert_raises(Assistant::ValidationDispatcher::DispatchFailed) do
        dispatch_validation
      end
    end

    request = Assistant::ValidationRequest.sole
    assert_equal "failed", request.status
    assert_nil request.source
    assert_includes request.result.fetch("codes"), "validator_dispatch_failed"
  end

  private

  def terminal_event(envelope)
    {
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "validation_id" => envelope.fetch("validation_id"),
      "correlation_id" => envelope.fetch("correlation_id"),
      "status" => "valid",
      "codes" => []
    }
  end

  def dispatch_validation
    Assistant::ValidationDispatcher.call(
      turn: @turn,
      grant: @grant,
      service_identity: @service_identity,
      yaml: SOURCE
    )
  end
end
