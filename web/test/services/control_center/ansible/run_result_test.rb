require "test_helper"

class ControlCenter::Ansible::RunResultTest < ActiveSupport::TestCase
  setup do
    @runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    @lease = SecureRandom.urlsafe_base64(32)
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "Deploy", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: users(:one)
    )
    @run = create_claimed_run
  end

  test "defines terminal run result handling" do
    assert defined?(ControlCenter::Ansible::RunResult), "expected RunResult to be defined"
  end

  test "first terminal result wins updates audit counts and purges payload and lease" do
    now = Time.current

    run = ControlCenter::Ansible::RunResult.call(
      run: @run,
      runner: @runner,
      lease: @lease,
      result: {
        status: "succeeded", exit_status: 0,
        ok_count: 3, changed_count: 1, failed_count: 0, unreachable_count: 0
      },
      now:
    )

    assert_equal "succeeded", run.status
    assert_equal 3, run.ok_count
    assert_equal 1, run.changed_count
    assert_nil run.lease_digest
    assert_nil run.lease_expires_at
    assert_in_delta now, run.completed_at, 0.001
    assert_equal "succeeded", run.run_group.reload.status
    assert_nil run.run_group.execution_payload
    assert_in_delta now, @credential.reload.last_used_at, 0.001
  end

  test "identical result retry succeeds and conflicting retry loses" do
    result = {
      status: "failed", exit_status: 2,
      ok_count: 1, changed_count: 0, failed_count: 1, unreachable_count: 0,
      error_code: "execution_failed", error_detail: "fleet-secret was rejected"
    }
    first = ControlCenter::Ansible::RunResult.call(
      run: @run, runner: @runner, lease: @lease, result:
    )

    retry_result = ControlCenter::Ansible::RunResult.call(
      run: first, runner: @runner, lease: @lease, result:
    )
    assert_equal first.id, retry_result.id
    assert_equal "[FILTERED] was rejected", retry_result.error_detail

    error = assert_raises(ControlCenter::Ansible::RunResult::Conflict) do
      ControlCenter::Ansible::RunResult.call(
        run: first, runner: @runner, lease: @lease,
        result: result.merge(status: "succeeded", exit_status: 0)
      )
    end
    assert_equal "result_conflict", error.code
  end

  test "rejects invalid terminal statuses and counts" do
    error = assert_raises(ControlCenter::Ansible::RunResult::Error) do
      ControlCenter::Ansible::RunResult.call(
        run: @run, runner: @runner, lease: @lease,
        result: { status: "running", ok_count: -1 }
      )
    end

    assert_equal "invalid_result", error.code
    assert_equal "running", @run.reload.status

    error = assert_raises(ControlCenter::Ansible::RunResult::Error) do
      ControlCenter::Ansible::RunResult.call(
        run: @run, runner: @runner, lease: @lease,
        result: {
          status: "failed", exit_status: 1,
          ok_count: 0, changed_count: 0, failed_count: 1, unreachable_count: 0,
          error_code: 123, error_detail: 456
        }
      )
    end
    assert_equal "invalid_result", error.code
  end

  private

  def create_claimed_run
    group = ControlCenter::Ansible::RunGroup.create!(
      created_by: users(:one), status: "running", credential: @credential,
      execution_payload: { "secrets" => { "ssh_password" => "fleet-secret" } }
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
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600
    )
  end
end
