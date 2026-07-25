require "test_helper"
require "base64"

class ControlCenter::Ansible::HostKeyConfirmationTest < ActiveSupport::TestCase
  setup do
    @inventory = ControlCenter::Ansible::Inventory.create!(
      name: "Workers",
      yaml_content: "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.10.0.8\n",
      created_by: users(:one)
    )
    @key_blob = Base64.strict_encode64("test-host-public-key")
    digest = Base64.strict_encode64(Digest::SHA256.digest("test-host-public-key")).delete_suffix("=")
    @fingerprint = "SHA256:#{digest}"
    @line = "worker ssh-ed25519 #{@key_blob}"
  end

  test "defines explicit host-key confirmation" do
    assert defined?(ControlCenter::Ansible::HostKeyConfirmation), "expected HostKeyConfirmation to be defined"
  end

  test "stores only a candidate whose scanned and independently entered fingerprints match" do
    result = ControlCenter::Ansible::HostKeyConfirmation.call(
      inventory: @inventory,
      candidates: [ candidate(expected_fingerprint: @fingerprint) ]
    )

    assert_equal @line, result.known_hosts
    assert_equal @fingerprint, result.host_key_fingerprints.fetch("worker:22")
  end

  test "mismatch or forged line stores nothing" do
    error = assert_raises(ControlCenter::Ansible::HostKeyConfirmation::Error) do
      ControlCenter::Ansible::HostKeyConfirmation.call(
        inventory: @inventory,
        candidates: [ candidate(expected_fingerprint: "SHA256:wrong") ]
      )
    end
    assert_equal "fingerprint_mismatch", error.code
    assert_nil @inventory.reload.known_hosts

    forged = candidate(expected_fingerprint: @fingerprint).merge(known_hosts_line: "other ssh-ed25519 #{@key_blob}")
    assert_raises(ControlCenter::Ansible::HostKeyConfirmation::Error) do
      ControlCenter::Ansible::HostKeyConfirmation.call(inventory: @inventory, candidates: [ forged ])
    end
    assert_nil @inventory.reload.known_hosts
  end

  private

  def candidate(expected_fingerprint:)
    {
      host: "worker",
      port: 22,
      known_hosts_line: @line,
      scanned_fingerprint: @fingerprint,
      expected_fingerprint:
    }
  end
end
