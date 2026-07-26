require "test_helper"

class Assistant::EventConsumerTest < ActiveSupport::TestCase
  Delivery = Data.define(:delivery_tag)
  Properties = Data.define(:content_type)

  class Channel
    attr_reader :acks, :rejections

    def initialize
      @acks = []
      @rejections = []
    end

    def ack(delivery_tag, multiple)
      @acks << [ delivery_tag, multiple ]
    end

    def reject(delivery_tag, requeue)
      @rejections << [ delivery_tag, requeue ]
    end
  end

  setup do
    @turn = assistant_turns(:created)
    @original_enabled = ENV["ASSISTANT_ENABLED"]
    ENV["ASSISTANT_ENABLED"] = "true"
    Assistant::Setting.instance.enable!
    @service_identity, = Assistant::ServiceIdentity.generate!(
      name: "consumer-test-mcp", role: "mcp_reader"
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

  test "routes validator events to terminal ingestion before acknowledging" do
    source = "---\n- hosts: workers\n  tasks:\n    - ansible.builtin.debug:\n        msg: ready\n"
    validation_id = nil
    stub_methods(Assistant::Broker, publish: true) do
      validation_id = Assistant::ValidationDispatcher.call(
        turn: @turn, grant: @grant, service_identity: @service_identity, yaml: source
      )
    end
    channel = Channel.new
    body = JSON.generate({
      "schema_version" => 1,
      "event_id" => SecureRandom.uuid,
      "validation_id" => validation_id,
      "correlation_id" => @turn.correlation_id,
      "status" => "valid",
      "codes" => []
    })

    Assistant::EventConsumer.consume(
      channel, Delivery.new(delivery_tag: "delivery-1"), Properties.new(content_type: "application/json"), body,
      queue: "assistant.rails.validation_events"
    )

    request = Assistant::ValidationRequest.find(validation_id)
    assert_equal "valid", request.status
    assert_nil request.source
    assert_equal source, request.result.fetch("normalized")
    assert_equal [ [ "delivery-1", false ] ], channel.acks
    assert_empty channel.rejections
  end
end
