require "test_helper"

class ControlCenter::Ansible::LeaseVerifierTest < ActiveSupport::TestCase
  test "defines the lease verifier" do
    assert defined?(ControlCenter::Ansible::LeaseVerifier), "expected LeaseVerifier to be defined"
  end

  test "accepts the owning runner exact lease active state and unexpired deadline" do
    runner, = Runner.generate(name: "ansible", kinds: [ "ansible" ])
    lease = SecureRandom.urlsafe_base64(32)
    run = build_claimed_run(runner:, lease:, status: "validating", lease_expires_at: 1.minute.from_now)

    verified = ControlCenter::Ansible::LeaseVerifier.verify!(
      run, runner:, lease:, statuses: %w[validating running], now: Time.current
    )

    assert_equal run, verified
  end

  test "rejects wrong runner wrong lease stale lease and disallowed state" do
    owner, = Runner.generate(name: "owner", kinds: [ "ansible" ])
    other, = Runner.generate(name: "other", kinds: [ "ansible" ])
    lease = SecureRandom.urlsafe_base64(32)
    run = build_claimed_run(runner: owner, lease:, status: "validating", lease_expires_at: 1.minute.from_now)

    error = assert_raises(ControlCenter::Ansible::LeaseVerifier::Conflict) do
      ControlCenter::Ansible::LeaseVerifier.verify!(run, runner: other, lease:, statuses: [ "validating" ])
    end
    assert_equal "lease_conflict", error.code

    assert_raises(ControlCenter::Ansible::LeaseVerifier::Conflict) do
      ControlCenter::Ansible::LeaseVerifier.verify!(run, runner: owner, lease: "wrong", statuses: [ "validating" ])
    end

    run.lease_expires_at = 1.second.ago
    assert_raises(ControlCenter::Ansible::LeaseVerifier::Conflict) do
      ControlCenter::Ansible::LeaseVerifier.verify!(run, runner: owner, lease:, statuses: [ "validating" ])
    end

    run.lease_expires_at = 1.minute.from_now
    run.status = "failed"
    assert_raises(ControlCenter::Ansible::LeaseVerifier::Conflict) do
      ControlCenter::Ansible::LeaseVerifier.verify!(run, runner: owner, lease:, statuses: [ "validating" ])
    end
  end

  private

  def build_claimed_run(runner:, lease:, status:, lease_expires_at:)
    group = ControlCenter::Ansible::RunGroup.new(created_by: users(:one))
    ControlCenter::Ansible::Run.new(
      run_group: group,
      runner:,
      lease_digest: Digest::SHA256.hexdigest(lease),
      lease_expires_at:,
      status:,
      position: 0,
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
