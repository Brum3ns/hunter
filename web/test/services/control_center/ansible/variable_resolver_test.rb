require "test_helper"

class ControlCenter::Ansible::VariableResolverTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::VariableResolver
  Variable = Data.define(:name, :typed_value, :secret)
  VariableSet = Data.define(:variables)
  Resource = Data.define(:variable_sets)

  test "resolves inventory playbook launch and override levels in ascending precedence" do
    inventory = Resource.new(variable_sets: [ variable_set(variable("release", "inventory"), variable("region", "eu")) ])
    playbook = Resource.new(variable_sets: [ variable_set(variable("release", "playbook")) ])
    launch_set = variable_set(variable("release", "launch"))

    result = Subject.call(
      inventory: inventory,
      playbooks: [ playbook ],
      launch_sets: [ launch_set ],
      overrides: [ { name: "release", value_type: "string", value: "override", secret: false } ]
    )

    assert result.valid?
    assert_equal({ "release" => "override", "region" => "eu" }, result.values)
    assert_equal result.values, result.audit_values
    assert_equal [], result.secret_names
    assert_equal [], result.secret_values
  end

  test "rejects duplicates within a level without merging that level" do
    inventory = Resource.new(variable_sets: [ variable_set(variable("release", "inventory")) ])
    playbook = Resource.new(variable_sets: [
      variable_set(variable("release", "first")),
      variable_set(variable("release", "second"), variable("playbook_only", true))
    ])

    result = Subject.call(inventory: inventory, playbooks: [ playbook ], launch_sets: [], overrides: [])

    refute result.valid?
    assert_equal [ 'duplicate variable "release" at playbook level' ], result.errors
    assert_equal({ "release" => "inventory" }, result.values)
  end

  test "reports duplicate launch overrides and preserves lower-level values" do
    inventory = Resource.new(variable_sets: [ variable_set(variable("count", 1)) ])
    overrides = [
      { name: "count", value_type: "number", value: 2, secret: false },
      { name: "count", value_type: "number", value: 3, secret: false }
    ]

    result = Subject.call(inventory: inventory, playbooks: [], launch_sets: [], overrides: overrides)

    assert_equal [ 'duplicate variable "count" at override level' ], result.errors
    assert_equal({ "count" => 1 }, result.values)
  end

  test "keeps secret values out of audit data and reports only effective secrets" do
    inventory = Resource.new(variable_sets: [
      variable_set(variable("token", "retired-secret", true), variable("region", "eu"))
    ])
    launch_set = variable_set(
      variable("token", "current-secret", true),
      variable("credentials", [ "nested-secret", "", 8443, false ], true)
    )

    result = Subject.call(
      inventory: inventory, playbooks: [], launch_sets: [ launch_set ], overrides: []
    )

    assert result.valid?
    assert_equal [ "credentials", "token" ], result.secret_names.sort
    assert_equal [ "8443", "current-secret", "false", "nested-secret" ], result.secret_values.sort
    assert_equal({ "region" => "eu" }, result.audit_values)
    refute_includes result.secret_values, "retired-secret"
  end

  test "returns typed override errors without partially merging the override level" do
    inventory = Resource.new(variable_sets: [ variable_set(variable("region", "eu")) ])

    result = Subject.call(
      inventory: inventory,
      playbooks: [],
      launch_sets: [],
      overrides: [
        { name: "good", value_type: "boolean", value: true, secret: false },
        { name: "bad", value_type: "boolean", value: "true", secret: false }
      ]
    )

    assert_equal [ 'override "bad" must be a boolean' ], result.errors
    assert_equal({ "region" => "eu" }, result.values)
  end

  test "rejects reserved connection names in launch overrides" do
    result = Subject.call(
      inventory: Resource.new(variable_sets: []),
      playbooks: [],
      launch_sets: [],
      overrides: [
        { name: "ANSIBLE_SSH_PASS", value_type: "string", value: "secret", secret: true }
      ]
    )

    assert_equal [ 'override "ANSIBLE_SSH_PASS" is reserved for connection credentials' ], result.errors
    assert_equal({}, result.values)
    assert_equal [], result.secret_values
  end

  private

  def variable(name, value, secret = false)
    Variable.new(name: name, typed_value: value, secret: secret)
  end

  def variable_set(*variables)
    VariableSet.new(variables: variables)
  end
end
