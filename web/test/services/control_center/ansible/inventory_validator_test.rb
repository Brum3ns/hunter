require "test_helper"

class ControlCenter::Ansible::InventoryValidatorTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::InventoryValidator

  VALID = <<~YAML
    ---
    all:
      children:
        workers:
          hosts:
            api-primary:
              ansible_host: 10.0.0.10
              ansible_port: 2222
          vars:
            deploy_env: production
  YAML

  test "accepts host aliases, ansible_host, and integer ports" do
    result = Subject.call(VALID)

    assert result.valid?
    assert_equal [], result.errors
  end

  test "requires a mapping root and mapping inventory sections" do
    scalar = Subject.call("---\nworkers\n")
    malformed = Subject.call("---\nall:\n  hosts: []\n  children: nope\n  vars: []\n")

    assert_equal [ "inventory must be a mapping" ], scalar.errors
    assert_equal [
      "all.hosts must be a mapping",
      "all.children must be a mapping",
      "all.vars must be a mapping"
    ], malformed.errors
  end

  test "rejects malformed ports" do
    string_port = Subject.call("---\nall:\n  hosts:\n    worker:\n      ansible_port: '22'\n")
    range_port = Subject.call("---\nall:\n  hosts:\n    worker:\n      ansible_port: 70000\n")

    assert_equal [ "all.hosts.worker.ansible_port must be an integer from 1 to 65535" ], string_port.errors
    assert_equal [ "all.hosts.worker.ansible_port must be an integer from 1 to 65535" ], range_port.errors
  end

  test "rejects local connections and reserved connection secrets" do
    result = Subject.call(<<~YAML)
      ---
      all:
        vars:
          ansible_connection: local
          ANSIBLE_SSH_PASS: secret
        hosts:
          worker:
            ansible_become_password: secret
    YAML

    assert_equal [
      "ansible_connection: local is not allowed",
      "ANSIBLE_SSH_PASS is a reserved connection variable",
      "ansible_become_password is a reserved connection variable"
    ], result.errors
  end

  test "rejects SSH arguments and executables that could bypass target or host-key policy" do
    result = Subject.call(<<~YAML)
      ---
      all:
        vars:
          ansible_ssh_common_args: -o StrictHostKeyChecking=no
          ansible_ssh_executable: /bin/sh
          ansible_paramiko_proxy_command: nc metadata 80
    YAML

    assert_equal [
      "ansible_ssh_common_args is a reserved connection variable",
      "ansible_ssh_executable is a reserved connection variable",
      "ansible_paramiko_proxy_command is a reserved connection variable"
    ], result.errors
  end

  test "rejects YAML aliases through the common parser" do
    result = Subject.call("---\nall: &all\n  hosts: {}\ncopy: *all\n")

    assert_equal [ "YAML aliases are not allowed" ], result.errors
  end
end
