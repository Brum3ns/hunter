require "test_helper"

class ControlCenter::Ansible::ExecutorTaskTest < ActiveSupport::TestCase
  test "defines the executor utility task model" do
    assert defined?(ControlCenter::Ansible::ExecutorTask), "expected ExecutorTask to be defined"
  end

  test "validates kind and status" do
    task = build_task(kind: "shell", status: "unknown")

    refute task.valid?
    assert task.errors[:kind].any?
    assert task.errors[:status].any?
  end

  test "encrypts its execution payload in the database" do
    task = build_task(execution_payload: { "ssh_password" => "fleet-secret" })
    task.save!

    raw = ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT execution_payload
      FROM control_center_ansible_executor_tasks
      WHERE id = #{task.id.to_i}
    SQL

    refute_includes raw, "fleet-secret"
    assert_equal "fleet-secret", task.reload.execution_payload.fetch("ssh_password")
  end

  test "only queued tasks are claimable and queued tasks are oldest first" do
    newer = build_task(created_at: 1.minute.ago)
    newer.save!
    older = build_task(created_at: 2.minutes.ago)
    older.save!
    running = build_task(status: "running", created_at: 3.minutes.ago)
    running.save!

    ControlCenter::Ansible::ExecutorTask::STATUSES.each do |status|
      assert_equal status == "queued", build_task(status:).claimable?, status
    end
    assert_equal [ older, newer ], ControlCenter::Ansible::ExecutorTask.queued.oldest_first.to_a
  end

  test "terminal predicate uses explicit terminal statuses" do
    %w[succeeded failed canceled].each do |status|
      assert build_task(status:).terminal?, "expected #{status} to be terminal"
    end
    %w[queued running].each do |status|
      refute build_task(status:).terminal?, "expected #{status} not to be terminal"
    end
  end

  private

  def build_task(attributes = {})
    ControlCenter::Ansible::ExecutorTask.new({
      kind: "syntax_check",
      status: "queued",
      created_by: users(:one),
      claim_deadline: 5.minutes.from_now
    }.merge(attributes))
  end
end
