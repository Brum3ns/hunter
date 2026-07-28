require "test_helper"

class ControlCenter::Ansible::PlaybookValidatorTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::PlaybookValidator

  VALID = <<~YAML
    ---
    - name: Baseline
      hosts: workers
      tasks:
        - name: Report
          ansible.builtin.debug:
            msg: ready
  YAML

  test "accepts a normal remote playbook" do
    result = Subject.call(VALID)

    assert result.valid?
    assert_equal [], result.errors
  end

  test "requires a nonempty array of play mappings with hosts" do
    scalar = Subject.call("---\nhello\n")
    mapping = Subject.call("---\nhosts: workers\n")
    empty = Subject.call("--- []\n")
    missing_hosts = Subject.call("---\n- name: Missing\n  tasks: []\n")

    assert_equal [ "playbook must be a non-empty array of plays" ], scalar.errors
    assert_equal [ "playbook must be a non-empty array of plays" ], mapping.errors
    assert_equal [ "playbook must be a non-empty array of plays" ], empty.errors
    assert_equal [ "play 1 must define non-blank hosts" ], missing_hosts.errors
  end

  test "requires task sections to be arrays" do
    result = Subject.call("---\n- hosts: workers\n  pre_tasks: nope\n  tasks: {}\n  handlers: task\n")

    assert_equal [
      "play 1 pre_tasks must be an array",
      "play 1 tasks must be an array",
      "play 1 handlers must be an array"
    ], result.errors
  end

  test "rejects connection selection and localhost delegation in nested tasks" do
    result = Subject.call(<<~YAML)
      ---
      - hosts: workers
        connection: ssh
        tasks:
          - block:
              - name: nested
                delegate_to: localhost
                local_action: command whoami
            rescue: []
            always: []
    YAML

    assert_equal [
      "connection is not configurable",
      "delegate_to: localhost is not allowed",
      "local_action is not allowed"
    ], result.errors
  end

  test "rejects SSH arguments that could weaken strict host-key checking" do
    result = Subject.call(<<~YAML)
      ---
      - hosts: workers
        vars:
          ansible_ssh_extra_args: -o UserKnownHostsFile=/dev/null
        tasks: []
    YAML

    assert_equal [ "ansible_ssh_extra_args is a reserved connection variable" ], result.errors
  end

  test "rejects reserved connection keys case insensitively anywhere" do
    result = Subject.call(<<~YAML)
      ---
      - hosts: workers
        vars:
          Ansible_Password: secret
        tasks:
          - ansible.builtin.debug:
              msg:
                ansible_private_key_file: /tmp/key
    YAML

    assert_equal [
      "Ansible_Password is a reserved connection variable",
      "ansible_private_key_file is a reserved connection variable"
    ], result.errors
  end

  test "propagates generic YAML safety errors" do
    result = Subject.call("---\n- hosts: workers\n  vars:\n    key: -----BEGIN OPENSSH PRIVATE KEY-----\n")

    assert_equal [ "embedded private keys are not allowed" ], result.errors
  end
end
