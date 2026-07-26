require "test_helper"

class Assistant::TurnDispatcherTest < ActiveSupport::TestCase
  setup do
    @turn = assistant_turns(:created)
    @turn.conversation.messages.create!(
      turn: @turn, role: "user", body: "draft a safe probe", sequence: 1
    )
    @raw_grant = Assistant::Grants::Issuer.call(
      turn: @turn,
      resources: [ { type: "program", id: "bugcrowd-acme" } ],
      tools: [ "get_selected_context" ]
    )
  end

  test "turn message is non-persistent and excludes all service credentials" do
    delivery = capture_publish do
      Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)
    end

    assert_equal false, delivery[:persistent]
    assert_equal 300_000, delivery[:expiration]
    assert_equal 1, delivery[:body]["schema_version"]
    assert_equal "draft a safe probe", delivery[:body]["user_message"]
    assert_equal @raw_grant, delivery[:body]["turn_grant"]
    assert_equal "queued", @turn.reload.status
    refute_includes delivery[:body].to_json, "provider_api_key"
    refute_includes delivery[:body].to_json, "mcp_service_token"
  end

  test "a publish failure leaves the turn undispatched" do
    assert_raises(StandardError) do
      stub_methods(Assistant::Broker, publish: ->(**) { raise "broker down" }) do
        Assistant::TurnDispatcher.call(turn: @turn, raw_grant: @raw_grant)
      end
    end

    assert_equal "created", @turn.reload.status
    assert_nil @turn.queued_at
  end

  private

  def capture_publish
    delivery = nil
    stub_methods(Assistant::Broker, publish: ->(**attributes) { delivery = attributes }) { yield }
    delivery
  end
end
