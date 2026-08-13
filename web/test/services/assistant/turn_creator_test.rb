require "test_helper"

class Assistant::TurnCreatorTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    @conversation = Assistant::Conversation.start!(
      user: @user,
      provider_profile: assistant_provider_profiles(:codex)
    )
    Assistant::Setting.instance.enable!
    @target = Target.new(
      "id" => "target-1",
      "target" => { "host" => "example.test", "url" => "https://example.test/path?token=secret" }
    )
  end

  test "persists direct chat authority and audit before enqueuing without resolving browser context" do
    enqueued = nil
    with_enabled_assistant do
      stub_methods(Assistant::Context::Resolver, find: ->(**) { flunk "direct chat resolved context" }) do
        stub_methods(Assistant::TurnJob, perform_later: lambda { |**attributes|
          enqueued = attributes
          # The job is enqueued only after TurnCreator's own transaction has
          # committed, so by the time this stub runs the turn must already be
          # readable as "queued" — proving the enqueue did not happen from
          # inside that transaction (see turn_creator.rb#dispatch).
          persisted = Assistant::Turn.find(attributes.fetch(:turn_id))
          assert_equal "queued", persisted.status
          assert_equal "Draft a safe probe", persisted.user_message.body
          assert_empty persisted.context_references
          assert Assistant::AuditEvent.exists?(event: "turn.created", turn_id: persisted.id)
        }) do
          @turn = Assistant::TurnCreator.call(
            conversation: @conversation,
            user: @user,
            body: "Draft a safe probe",
            context_refs: [ { type: "target", id: "target-1" } ]
          )
        end
      end
    end

    assert_equal "queued", @turn.reload.status
    grant = @turn.turn_grant
    assert_empty grant.resources
    assert_equal Assistant::Grants::Issuer::CHAT_TOOLS, grant.tools
    assert_equal @turn.id, enqueued.fetch(:turn_id)
    refute_equal enqueued.dig(:envelope, "turn_grant"), grant.token_digest
  end

  test "a Claude Code turn issues a per-turn grant and enqueues TurnJob with the raw token" do
    profile = assistant_provider_profiles(:claude_code)
    conversation = Assistant::Conversation.start!(user: @user, provider_profile: profile)
    enqueued = nil

    with_enabled_assistant do
      stub_methods(Assistant::TurnJob, perform_later: lambda { |**attributes|
        # `raw_grant` is cleared in TurnCreator's `ensure` right after this stub
        # runs, before control returns to this test — dup the token now (as a
        # real ActiveJob adapter would serialize it into the persisted job row
        # before that clear happens) so we can still inspect its real value.
        enqueued = attributes.merge(turn_grant: attributes[:turn_grant]&.dup)
      }) do
        @turn = Assistant::TurnCreator.call(
          conversation: conversation,
          user: @user,
          body: "hi claude",
          context_refs: []
        )
      end
    end

    assert_equal "queued", @turn.reload.status
    grant = @turn.turn_grant
    refute_nil grant, "the Claude Code path must now issue a TurnGrant bound to the turn"
    assert_equal [], grant.resources
    assert_equal Assistant::Grants::Issuer::CHAT_TOOLS, grant.tools
    assert_equal Assistant::TurnGrant::READ_SCOPES, grant.read_scopes
    assert_equal Assistant::TurnGrant::WRITE_SCOPES, grant.write_scopes

    assert_equal @turn.id, enqueued.fetch(:turn_id)
    assert_equal true, enqueued.fetch(:claude)
    assert_equal "hi claude", enqueued.fetch(:prompt)
    refute_nil enqueued.fetch(:turn_grant)
    refute_equal enqueued.fetch(:turn_grant), grant.token_digest
    assert_equal Assistant::TurnGrant.digest(enqueued.fetch(:turn_grant)), grant.token_digest
  end


  test "a Claude Code turn loses only authoring tools and scopes when Control Center writes are off" do
    profile = assistant_provider_profiles(:claude_code)
    conversation = Assistant::Conversation.start!(user: @user, provider_profile: profile)
    Assistant::Setting.instance.update!(control_center_write_enabled: false)

    with_enabled_assistant do
      stub_methods(Assistant::TurnJob, perform_later: ->(**) { true }) do
        @turn = Assistant::TurnCreator.call(
          conversation: conversation,
          user: @user,
          body: "inspect without authoring",
          context_refs: []
        )
      end
    end

    grant = @turn.turn_grant
    assert_equal Assistant::Grants::Issuer::CHAT_READ_TOOLS, grant.tools
    assert_equal Assistant::TurnGrant::READ_SCOPES, grant.read_scopes
    assert_equal [], grant.write_scopes
  end

  test "a legacy profile is rejected before rate authority audit context or enqueue side effects" do
    legacy = assistant_conversations(:one)
    counts = record_counts
    rate_consumed = false
    context_resolved = false
    enqueued = false

    error = assert_raises(Assistant::TurnCreator::Rejected) do
      with_enabled_assistant do
        stub_methods(Assistant::RateLimiter, consume!: ->(**) { rate_consumed = true }) do
          stub_methods(Assistant::Context::Resolver, find: lambda { |**|
            context_resolved = true
            nil
          }) do
            stub_methods(Assistant::TurnJob, perform_later: ->(**) { enqueued = true }) do
              Assistant::TurnCreator.call(
                conversation: legacy,
                user: @user,
                body: "Do not revive this provider",
                context_refs: [ { type: "target", id: "target-1" } ]
              )
            end
          end
        end
      end
    end

    assert_instance_of Assistant::TurnCreator::Rejected, error
    assert_equal "legacy_provider_retired", error.code
    assert_equal counts, record_counts
    refute rate_consumed
    refute context_resolved
    refute enqueued
  end

  test "an enqueue failure interrupts the persisted turn and revokes its grant" do
    turn = nil

    with_enabled_assistant do
      stub_methods(Assistant::TurnJob, perform_later: ->(**) { raise "queue adapter down" }) do
        turn = Assistant::TurnCreator.call(
          conversation: @conversation,
          user: @user,
          body: "Draft without context",
          context_refs: []
        )
      end
    end

    assert_equal "interrupted", turn.reload.status
    assert_equal "assistant_dispatch_unavailable", turn.error_code
    assert_not_nil turn.completed_at
    assert_not_nil turn.turn_grant.revoked_at
    failure = Assistant::AuditEvent.find_by!(event: "turn.dispatch_failed", turn_id: turn.id)
    assert_equal "retryable", failure.status
    assert_equal "assistant_dispatch_unavailable", failure.metadata.fetch("reason")
  end

  test "ownership and current profile review are rechecked under the conversation lock" do
    error = assert_raises(Assistant::TurnCreator::Rejected) do
      with_enabled_assistant do
        Assistant::TurnCreator.call(
          conversation: @conversation,
          user: users(:two),
          body: "Not mine",
          context_refs: []
        )
      end
    end
    assert_equal "conversation_not_found", error.code

    @conversation.provider_profile.update!(enabled: false)
    error = assert_raises(Assistant::TurnCreator::Rejected) do
      with_enabled_assistant do
        Assistant::TurnCreator.call(
          conversation: @conversation,
          user: @user,
          body: "Profile was disabled",
          context_refs: []
        )
      end
    end
    assert_equal "provider_profile_unavailable", error.code
  end

  test "the database administrator kill switch rejects every direct backend" do
    Assistant::Setting.instance.disable!(user: @user)

    %i[codex claude_code].each do |fixture_name|
      conversation = Assistant::Conversation.start!(
        user: @user,
        provider_profile: assistant_provider_profiles(fixture_name)
      )
      counts = record_counts

      error = assert_raises(Assistant::TurnCreator::Rejected) do
        stub_methods(Assistant::Config, { enabled?: true, max_records: 10 }) do
          Assistant::TurnCreator.call(
            conversation: conversation,
            user: @user,
            body: "Database-disabled",
            context_refs: []
          )
        end
      end

      assert_equal "assistant_disabled", error.code
      assert_equal counts, record_counts
    end
  end

  test "settings and provider review rows are locked through the dispatch claim" do
    sql = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql << payload.fetch(:sql) unless payload[:name] == "SCHEMA"
    end

    with_enabled_assistant do
      stub_methods(Assistant::TurnJob, perform_later: ->(**) { true }) do
        Assistant::TurnCreator.call(
          conversation: @conversation,
          user: @user,
          body: "Lock reviewed dispatch state",
          context_refs: []
        )
      end
    end

    assert sql.any? { |statement| statement.match?(/assistant_settings.*FOR UPDATE/i) },
      "assistant settings must be row-locked"
    assert sql.any? { |statement| statement.match?(/assistant_provider_profiles.*FOR UPDATE/i) },
      "provider profile must be row-locked"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "rate rejection persists no turn authority and never enqueues" do
    counts = record_counts
    enqueued = false
    limit = Assistant::RateLimiter::LimitExceeded.new(
      "turn_rate_minute_exceeded", retry_after_seconds: 30
    )

    stub_methods(Assistant::RateLimiter, consume!: ->(**) { raise limit }) do
      stub_methods(Assistant::TurnJob, perform_later: ->(**) { enqueued = true }) do
        assert_raises(Assistant::RateLimiter::LimitExceeded) do
          with_enabled_assistant do
            Assistant::TurnCreator.call(
              conversation: @conversation,
              user: @user,
              body: "Rate limited",
              context_refs: []
            )
          end
        end
      end
    end

    assert_equal counts, record_counts
    refute enqueued
  end

  private

  def with_enabled_assistant(&block)
    stub_methods(Assistant::Config, { enabled?: true, max_records: 10 }, &block)
  end

  def record_counts
    {
      turns: Assistant::Turn.count,
      messages: Assistant::Message.count,
      contexts: Assistant::ContextReference.count,
      grants: Assistant::TurnGrant.count,
      audits: Assistant::AuditEvent.count
    }
  end
end
