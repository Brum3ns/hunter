require "test_helper"

class ControlCenter::Ansible::RunEventIngestorTest < ActiveSupport::TestCase
  setup do
    @runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    @lease = SecureRandom.urlsafe_base64(32)
    @run = create_claimed_run
  end

  test "defines the bounded event ingestor" do
    assert defined?(ControlCenter::Ansible::RunEventIngestor), "expected RunEventIngestor to be defined"
  end

  test "redacts stdout structured values and exact secret keys before persistence" do
    events = [ {
      event_uuid: "event-1",
      counter: 1,
      event_type: "runner_on_ok",
      stdout: "fleet-secret variable-secret safe-value",
      event_data: {
        "fleet-secret" => "variable-secret",
        "nested" => [ "x-fleet-secret-y", "safe-value" ]
      }
    } ]

    result = ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease, events:
    )
    event = result.sole

    assert_equal "[FILTERED] [FILTERED] safe-value", event.stdout
    assert_equal "[FILTERED]", event.event_data.fetch("[FILTERED]")
    assert_equal [ "x-[FILTERED]-y", "safe-value" ], event.event_data.fetch("nested")
    refute_includes JSON.generate(event.attributes), "fleet-secret"
    refute_includes JSON.generate(event.attributes), "variable-secret"
    assert_operator @run.reload.stored_event_bytes, :>, 0
  end

  test "accepts an identical retry without duplicating bytes or rows" do
    event = {
      event_uuid: "event-1", counter: 1, event_type: "runner_on_ok",
      event_time: "2026-07-24T10:00:00Z", stdout: "ok"
    }
    first = ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease, events: [ event ]
    ).sole
    bytes = @run.reload.stored_event_bytes

    second = ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease, events: [ event ]
    ).sole

    assert_equal first.id, second.id
    assert_equal 1, @run.run_events.count
    assert_equal bytes, @run.reload.stored_event_bytes
  end

  test "rejects conflicting UUID or counter retries" do
    ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease,
      events: [ { event_uuid: "event-1", counter: 1, event_type: "runner_on_ok", stdout: "first" } ]
    )

    error = assert_raises(ControlCenter::Ansible::RunEventIngestor::Error) do
      ControlCenter::Ansible::RunEventIngestor.call(
        run: @run, runner: @runner, lease: @lease,
        events: [ { event_uuid: "event-1", counter: 2, event_type: "runner_on_failed", stdout: "changed" } ]
      )
    end

    assert_equal "event_conflict", error.code
  end

  test "enforces batch per-event and total-run caps" do
    error = assert_raises(ControlCenter::Ansible::RunEventIngestor::Error) do
      ControlCenter::Ansible::RunEventIngestor.call(
        run: @run, runner: @runner, lease: @lease,
        events: Array.new(101) { |index| { event_uuid: "event-#{index}", counter: index, event_type: "ok" } }
      )
    end
    assert_equal "invalid_events", error.code

    oversized = ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease,
      events: [ { event_uuid: "large", counter: 1, event_type: "verbose", stdout: "x" * 80.kilobytes } ]
    ).sole
    assert oversized.truncated
    assert_operator oversized.stdout.bytesize, :<=, ControlCenter::Ansible::SecretRedactor::MAX_BYTES

    @run.update_columns(stored_event_bytes: ControlCenter::Ansible::RunEventIngestor::MAX_RUN_BYTES - 5)
    capped = ControlCenter::Ansible::RunEventIngestor.call(
      run: @run, runner: @runner, lease: @lease,
      events: [ { event_uuid: "capped", counter: 2, event_type: "verbose", stdout: "not stored" } ]
    ).sole
    assert capped.truncated
    assert_nil capped.stdout
    assert_equal({}, capped.event_data)
    assert_operator @run.reload.stored_event_bytes, :<=, ControlCenter::Ansible::RunEventIngestor::MAX_RUN_BYTES
  end

  private

  def create_claimed_run
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: users(:one),
      status: "running",
      execution_payload: {
        "secrets" => { "ssh_password" => "fleet-secret" },
        "variables" => { "token" => "variable-secret", "public" => "safe-value" }
      }
    )
    group.runs.create!(
      position: 0,
      status: "running",
      runner: @runner,
      lease_digest: Digest::SHA256.hexdigest(@lease),
      lease_expires_at: 1.minute.from_now,
      playbook_yaml: "--- playbook",
      inventory_yaml: "--- inventory",
      known_hosts: "known hosts",
      variable_audit: { "public" => "safe-value" },
      secret_variable_names: [ "token" ],
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end
end
