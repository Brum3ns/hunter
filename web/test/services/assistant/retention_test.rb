require "test_helper"

class Assistant::RetentionTest < ActiveSupport::TestCase
  test "purges expired conversation content while retaining independent audits" do
    now = Time.zone.parse("2026-07-26 12:00:00 UTC")
    conversation = assistant_conversations(:one)
    conversation.messages.create!(role: "user", body: "expired secret body", sequence: 1)
    conversation.update_column(:expires_at, now)
    retained_audit = Assistant::AuditEvent.create!(
      event: "conversation.created",
      conversation: conversation,
      user: conversation.user,
      expires_at: now + 1.day
    )

    result = Assistant::Retention.purge!(now: now)

    refute Assistant::Conversation.exists?(conversation.id)
    assert_equal 0, Assistant::Message.where(conversation_id: conversation.id).count
    assert Assistant::AuditEvent.exists?(retained_audit.id)
    assert_nil retained_audit.reload.conversation_id
    assert_equal 1, result.fetch(:conversations)
  end

  test "deletes expired audits and validation records and revokes expired grants at the boundary" do
    now = Time.zone.parse("2026-07-26 12:00:00 UTC")
    turn = assistant_turns(:created)
    Assistant::Grants::Issuer.call(
      turn: turn, resources: [], tools: [ "validate_ansible_draft" ]
    )
    grant = turn.reload.turn_grant
    grant.update_column(:expires_at, now)
    validation = Assistant::ValidationRequest.create!(
      turn: turn,
      turn_grant: grant,
      source: "---\n- hosts: workers\n  tasks: []\n",
      expires_at: now
    )
    expired_audit = Assistant::AuditEvent.create!(event: "grant.expired", expires_at: now)
    future_audit = Assistant::AuditEvent.create!(event: "grant.created", expires_at: now + 1.second)

    result = Assistant::Retention.purge!(now: now)

    assert_not_nil grant.reload.revoked_at
    refute Assistant::ValidationRequest.exists?(validation.id)
    refute Assistant::AuditEvent.exists?(expired_audit.id)
    assert Assistant::AuditEvent.exists?(future_audit.id)
    assert_equal({ conversations: 0, grants: 1, validations: 1, audits: 1 }, result)
  end

  test "batches destructive work and logs counts without transcript bodies" do
    now = Time.zone.parse("2026-07-26 12:00:00 UTC")
    body = "do-not-log-retained-secret"
    conversations = 3.times.map do |index|
      conversation = Assistant::Conversation.start!(
        user: users(:one), provider_profile: assistant_provider_profiles(:openai)
      )
      conversation.messages.create!(role: "user", body: "#{body}-#{index}", sequence: 1)
      conversation.update_column(:expires_at, now - 1.second)
      conversation
    end
    messages = []

    stub_methods(Rails.logger, info: ->(message) { messages << message }) do
      stub_const(Assistant::Retention, :BATCH_SIZE, 2) do
        Assistant::Retention.purge!(now: now)
      end
    end

    assert conversations.none? { |conversation| Assistant::Conversation.exists?(conversation.id) }
    assert messages.any? { |message| message.include?("conversations=3") }
    refute_includes messages.join(" "), body
  end

  private

  def stub_const(mod, name, value)
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end
end
