require "test_helper"

class Assistant::DraftValidation::AnsibleStaticTest < ActiveSupport::TestCase
  VALID = <<~YAML
    ---
    - name: Explain selection
      hosts: workers
      gather_facts: false
      tasks:
        - name: Report
          ansible.builtin.debug:
            msg: ready
  YAML

  setup do
    @original_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
  end

  teardown do
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_allowlist
  end

  test "fails closed when the deployment module allowlist is empty" do
    ENV.delete("ASSISTANT_ANSIBLE_MODULE_ALLOWLIST")

    result = Assistant::DraftValidation::AnsibleStatic.call(VALID)

    refute result.valid?
    assert_includes result.codes, "assistant_ansible_policy_unconfigured"
  end

  test "rejects execution and dependency-loading modules even if configured" do
    modules = %w[
      ansible.builtin.shell ansible.builtin.command ansible.builtin.raw ansible.builtin.script
      ansible.builtin.include_tasks ansible.builtin.import_tasks ansible.builtin.include_role
      ansible.builtin.import_role
    ]
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = modules.join(",")

    modules.each do |mod|
      result = Assistant::DraftValidation::AnsibleStatic.call(<<~YAML)
        ---
        - hosts: workers
          tasks:
            - #{mod}: unsafe
      YAML

      refute result.valid?, mod
      assert_includes result.codes, "ansible_module_not_allowed", mod
    end
  end

  test "rejects roles collections lookups environment and absolute paths" do
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    fixtures = {
      "ansible_roles_not_allowed" => "roles:\n    - external.role",
      "ansible_collections_not_allowed" => "collections:\n    - external.collection",
      "ansible_lookup_not_allowed" => "vars:\n    value: \"{{ lookup('env', 'TOKEN') }}\"",
      "ansible_environment_not_allowed" => "environment:\n    TOKEN: secret",
      "ansible_absolute_path_not_allowed" => "vars:\n    source: /etc/passwd"
    }

    fixtures.each do |code, fragment|
      result = Assistant::DraftValidation::AnsibleStatic.call(<<~YAML)
        ---
        - hosts: workers
          #{fragment}
          tasks:
            - ansible.builtin.debug:
                msg: ready
      YAML

      refute result.valid?, code
      assert_includes result.codes, code
      refute_includes result.messages.join(" "), "TOKEN"
      refute_includes result.messages.join(" "), "/etc/passwd"
    end
  end

  test "rejects dependency paths module defaults and relative path traversal" do
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug,ansible.builtin.include_vars"
    fixtures = [
      [ "ansible_dependency_not_allowed", "vars_files:\n    - safe-looking.yml" ],
      [ "ansible_dependency_not_allowed", "module_defaults:\n    ansible.builtin.debug:\n      verbosity: 1" ],
      [ "ansible_path_traversal_not_allowed", "vars:\n    source: ../../etc/passwd" ]
    ]

    fixtures.each do |code, fragment|
      result = Assistant::DraftValidation::AnsibleStatic.call(<<~YAML)
        ---
        - hosts: workers
          #{fragment}
          tasks:
            - ansible.builtin.debug:
                msg: ready
      YAML

      refute result.valid?, fragment
      assert_includes result.codes, code
    end

    result = Assistant::DraftValidation::AnsibleStatic.call(<<~YAML)
      ---
      - hosts: workers
        tasks:
          - ansible.builtin.include_vars: ../../etc/passwd
    YAML
    refute result.valid?
    assert_includes result.codes, "ansible_module_not_allowed"
  end

  test "accepts only an explicitly allowed remote module" do
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"

    result = Assistant::DraftValidation::AnsibleStatic.call(VALID)

    assert result.valid?
    assert_equal VALID, result.normalized
    assert_equal "ansible-static-v1", result.validation_version
  end

  test "rejects source above the assistant 64 KiB limit before generic validation" do
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
    generic_validator_called = false
    source = "-" * 65_537

    stub_methods(ControlCenter::Ansible::PlaybookValidator,
      call: ->(*) { generic_validator_called = true }) do
      result = Assistant::DraftValidation::AnsibleStatic.call(source)

      refute result.valid?
      assert_includes result.codes, "ansible_source_too_large"
      refute generic_validator_called
    end
  end
end
