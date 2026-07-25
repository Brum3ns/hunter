require "test_helper"

class ControlCenter::Ansible::RunTest < ActiveSupport::TestCase
  test "defines the execution run model" do
    assert defined?(ControlCenter::Ansible::Run), "expected Run to be defined"
  end

  test "validates status and timeout bounds" do
    run = build_run(status: "unknown", timeout_seconds: 59)

    refute run.valid?
    assert run.errors[:status].any?
    assert run.errors[:timeout_seconds].any?

    run.timeout_seconds = 86_401
    refute run.valid?
    assert run.errors[:timeout_seconds].any?
  end

  test "only queued runs are claimable" do
    ControlCenter::Ansible::Run::STATUSES.each do |status|
      assert_equal status == "queued", build_run(status:).claimable?, status
    end
  end

  test "queued scope excludes other states and orders oldest first" do
    newest = build_run(status: "queued", queued_at: 1.minute.ago)
    newest.save!
    oldest = build_run(status: "queued", queued_at: 2.minutes.ago)
    oldest.save!
    build_run(status: "running", queued_at: 3.minutes.ago).save!

    assert_equal [ oldest, newest ], ControlCenter::Ansible::Run.queued.oldest_first.to_a
  end

  test "execution snapshots are immutable after persistence" do
    run = build_run
    run.save!

    refute run.update(playbook_yaml: "---\n- hosts: changed\n")
    assert_includes run.errors[:playbook_yaml], "cannot be changed after launch"
  end

  test "terminal predicate uses explicit terminal statuses" do
    %w[succeeded failed canceled skipped].each do |status|
      assert build_run(status:).terminal?, "expected #{status} to be terminal"
    end
    %w[waiting queued validating running canceling].each do |status|
      refute build_run(status:).terminal?, "expected #{status} not to be terminal"
    end
  end

  private

  def build_run(attributes = {})
    group = attributes.delete(:run_group) || ControlCenter::Ansible::RunGroup.new(created_by: users(:one))
    ControlCenter::Ansible::Run.new({
      run_group: group,
      position: 0,
      status: "queued",
      playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
      inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
      known_hosts: "worker ssh-ed25519 AAAA",
      variable_audit: { "port" => 22 },
      secret_variable_names: [ "deploy_token" ],
      playbook_name: "Baseline",
      inventory_name: "Workers",
      credential_name: "Deploy",
      timeout_seconds: 3600,
      queued_at: Time.current
    }.merge(attributes))
  end
end
