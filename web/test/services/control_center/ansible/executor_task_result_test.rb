require "test_helper"

class ControlCenter::Ansible::ExecutorTaskResultTest < ActiveSupport::TestCase
  setup do
    @runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    @lease = SecureRandom.urlsafe_base64(32)
    @task = ControlCenter::Ansible::ExecutorTask.create!(
      kind: "syntax_check",
      status: "running",
      created_by: users(:one),
      execution_payload: { "yaml" => "secret material" },
      runner: @runner,
      lease_digest: Digest::SHA256.hexdigest(@lease),
      lease_expires_at: 1.minute.from_now,
      claim_deadline: 5.minutes.from_now
    )
  end

  test "defines utility-task result handling" do
    assert defined?(ControlCenter::Ansible::ExecutorTaskResult), "expected ExecutorTaskResult to be defined"
  end

  test "persists one terminal result and purges payload and lease" do
    task = ControlCenter::Ansible::ExecutorTaskResult.call(
      task: @task, runner: @runner, lease: @lease,
      result: { status: "succeeded", result: { "valid" => true } }
    )

    assert_equal "succeeded", task.status
    assert_equal({ "valid" => true, "errors" => [] }, task.result)
    assert_nil task.execution_payload
    assert_nil task.lease_digest
    assert task.completed_at
  end

  test "allows an identical retry and rejects a conflicting one" do
    attributes = { status: "failed", result: {}, error_code: "syntax_invalid", error_detail: "invalid" }
    first = ControlCenter::Ansible::ExecutorTaskResult.call(
      task: @task, runner: @runner, lease: @lease, result: attributes
    )

    assert_equal first.id, ControlCenter::Ansible::ExecutorTaskResult.call(
      task: first, runner: @runner, lease: @lease, result: attributes
    ).id
    assert_raises(ControlCenter::Ansible::ExecutorTaskResult::Conflict) do
      ControlCenter::Ansible::ExecutorTaskResult.call(
        task: first, runner: @runner, lease: @lease,
        result: attributes.merge(status: "succeeded", result: { "valid" => true })
      )
    end
  end

  test "host-key scan results are allowlisted and remain explicitly untrusted" do
    @task.update_columns(kind: "host_key_scan")

    task = ControlCenter::Ansible::ExecutorTaskResult.call(
      task: @task,
      runner: @runner,
      lease: @lease,
      result: {
        status: "succeeded",
        result: {
          "candidates" => [ {
            "host" => "worker", "port" => 22,
            "known_hosts_line" => "worker ssh-ed25519 AAAA",
            "fingerprint" => "SHA256:test", "trusted" => true,
            "ssh_password" => "must-not-persist"
          } ],
          "command_output" => "must-not-persist"
        }
      }
    )

    assert_equal [ {
      "host" => "worker", "port" => 22,
      "known_hosts_line" => "worker ssh-ed25519 AAAA",
      "fingerprint" => "SHA256:test", "trusted" => false
    } ], task.result.fetch("candidates")
    refute_match(/password|command_output|must-not-persist/i, JSON.generate(task.result))
  end
end
