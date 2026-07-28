require "test_helper"

class Assistant::KillSwitchTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    Assistant::Setting.instance.enable!
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created), resources: [], tools: [ "get_authoring_policy" ]
    )
    Assistant::ServiceIdentity.generate!(name: "mcp", role: "mcp_reader")
    ApiToken.generate(user: @user, name: "ordinary", scopes: [ "control_center" ])
    Runner.generate(name: "ordinary-runner", kinds: [ "curl" ])
  end

  test "atomically disables authority without changing ordinary APIs or executors" do
    api_token_ids = ApiToken.ids
    runner_ids = Runner.ids

    result = Assistant::KillSwitch.disable!(user: @user)

    setting = Assistant::Setting.instance.reload
    refute setting.assistant_enabled?
    assert_equal @user, setting.disabled_by
    assert Assistant::TurnGrant.where(revoked_at: nil).none?
    assert Assistant::ServiceIdentity.where(enabled: true).none?
    assert Assistant::Turn.where.not(status: Assistant::Turn::TERMINAL_STATUSES).none?
    assert_equal api_token_ids, ApiToken.ids
    assert_equal runner_ids, Runner.ids
    assert_equal "disabled", result.status

    audit = Assistant::AuditEvent.find_by!(event: "kill_switch.disabled")
    assert_equal @user, audit.user
    assert_equal "disabled", audit.status
    assert_equal({ "operation" => "kill_switch", "outcome" => "disabled" }, audit.metadata)
  end

  test "re-enabling settings does not restore identities grants or turns" do
    Assistant::KillSwitch.disable!(user: @user)

    Assistant::Setting.instance.enable!

    assert Assistant::Setting.instance.reload.assistant_enabled?
    assert Assistant::TurnGrant.where(revoked_at: nil).none?
    assert Assistant::ServiceIdentity.where(enabled: true).none?
    assert Assistant::Turn.where.not(status: Assistant::Turn::TERMINAL_STATUSES).none?
  end

  test "audit failure rolls the entire shutdown back" do
    stub_methods(Assistant::Audit,
      record!: ->(**) { raise ActiveRecord::StatementInvalid, "audit unavailable" }) do
      assert_raises(ActiveRecord::StatementInvalid) do
        Assistant::KillSwitch.disable!(user: @user)
      end
    end

    assert Assistant::Setting.instance.reload.assistant_enabled?
    assert Assistant::TurnGrant.where(revoked_at: nil).exists?
    assert Assistant::ServiceIdentity.where(enabled: true).exists?
    assert Assistant::Turn.where.not(status: Assistant::Turn::TERMINAL_STATUSES).exists?
  end
end

class Assistant::KillSwitchConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:one)
    @turn = assistant_turns(:created)
    @turn.update!(status: "created", error_code: nil, completed_at: nil)
    Assistant::Setting.instance.enable!
    Assistant::TurnGrant.where(turn: @turn).delete_all
    Assistant::Grants::Issuer.call(
      turn: @turn, resources: [], tools: [ "get_authoring_policy" ]
    )
  end

  test "shutdown does not deadlock a turn terminalizing before its grant" do
    turn_locked = Queue.new
    continue_terminalization = Queue.new
    kill_grant_update_seen = Queue.new
    errors = Queue.new

    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      if Thread.current[:assistant_kill_switch_test] &&
          payload[:sql].match?(/UPDATE .*assistant_turn_grants/i)
        kill_grant_update_seen << true
      end
    end

    terminalizer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Assistant::Turn.transaction do
          turn = Assistant::Turn.find(@turn.id)
          turn.lock!
          turn_locked << true
          continue_terminalization.pop
          now = Time.current
          turn.update!(status: "canceled", completed_at: now)
          Assistant::TurnGrant.where(turn: turn, revoked_at: nil).update_all(
            revoked_at: now, updated_at: now
          )
        end
      end
    rescue StandardError => error
      errors << error
    end

    turn_locked.pop
    shutdown = Thread.new do
      Thread.current[:assistant_kill_switch_test] = true
      ActiveRecord::Base.connection_pool.with_connection do
        Assistant::KillSwitch.disable!(user: @user)
      end
    rescue StandardError => error
      errors << error
    end

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.5
    loop do
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      break if !kill_grant_update_seen.empty?

      Thread.pass
    end
    continue_terminalization << true

    [ terminalizer, shutdown ].each { |thread| thread.join(5) }
    assert [ terminalizer, shutdown ].none?(&:alive?), "concurrent shutdown did not finish"
    raised = drain_queue(errors)
    assert_empty raised, -> { "concurrent shutdown raised: #{raised.map(&:class).join(", ")}" }
    refute Assistant::Setting.instance.reload.assistant_enabled?
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    [ terminalizer, shutdown ].compact.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  private

  def drain_queue(queue)
    values = []
    loop { values << queue.pop(true) }
  rescue ThreadError
    values
  end
end
