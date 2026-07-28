require "test_helper"

class ControlCenter::Ansible::RunPayloadTest < ActiveSupport::TestCase
  Resolution = Data.define(:values)

  test "defines the immutable payload builder" do
    assert defined?(ControlCenter::Ansible::RunPayload), "expected RunPayload to be defined"
  end

  test "builds the exact versioned executor payload" do
    playbook = Data.define(:yaml_content).new(yaml_content: "--- playbook")
    inventory = Data.define(:yaml_content, :known_hosts).new(
      yaml_content: "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.20.1.8\n",
      known_hosts: "worker ssh-ed25519 AAAA"
    )
    credential = Data.define(
      :username, :private_key, :ssh_password, :private_key_passphrase, :become_password
    ).new(
      username: "deploy", private_key: "PRIVATE", ssh_password: nil,
      private_key_passphrase: "key-pass", become_password: "sudo-pass"
    )

    payload = ControlCenter::Ansible::RunPayload.call(
      playbook:, inventory:, credential:,
      resolution: Resolution.new(values: { "release" => "2026.07" }),
      host_limit: "workers", check_mode: true, timeout_seconds: 900
    )

    assert_equal(
      {
        "schema_version" => 1,
        "playbook_yaml" => "--- playbook",
        "inventory_yaml" => "---\nall:\n  hosts:\n    worker:\n      ansible_host: 10.20.1.8\n",
        "known_hosts" => "worker ssh-ed25519 AAAA",
        "targets" => [ { "host" => "worker", "address" => "10.20.1.8", "port" => 22 } ],
        "variables" => { "release" => "2026.07" },
        "secrets" => {
          "username" => "deploy",
          "private_key" => "PRIVATE",
          "ssh_password" => nil,
          "private_key_passphrase" => "key-pass",
          "become_password" => "sudo-pass"
        },
        "options" => { "host_limit" => "workers", "check_mode" => true, "timeout_seconds" => 900 }
      },
      payload
    )
  end
end
