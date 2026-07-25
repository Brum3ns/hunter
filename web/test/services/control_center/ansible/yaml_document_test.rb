require "test_helper"

class ControlCenter::Ansible::YamlDocumentTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::YamlDocument

  test "safe loads ordinary YAML while preserving its document" do
    result = Subject.call("---\nname: baseline\nitems:\n  - one\n")

    assert result.valid?
    assert_equal({ "name" => "baseline", "items" => [ "one" ] }, result.document)
  end

  test "rejects oversized input before parsing" do
    result = Subject.call("x" * (ControlCenter::Ansible::YamlLimits::MAX_BYTES + 1))

    assert_equal [ "exceeds the maximum size of 262144 bytes" ], result.errors
  end

  test "rejects aliases" do
    result = Subject.call("---\ndefaults: &defaults\n  value: one\ncopy: *defaults\n")

    assert_equal [ "YAML aliases are not allowed" ], result.errors
  end

  test "rejects custom and vault tags" do
    custom = Subject.call("---\nvalue: !custom hello\n")
    vault = Subject.call("---\nvalue: !vault |\n  $ANSIBLE_VAULT;1.1;AES256\n")

    assert_equal [ "custom YAML tags are not allowed" ], custom.errors
    assert_equal [ "Ansible Vault content is not supported" ], vault.errors
  end

  test "rejects vault markers and PEM boundaries in ordinary scalars" do
    vault = Subject.call("---\nvalue: '$ANSIBLE_VAULT;1.1;AES256'\n")
    pem = Subject.call("---\nvalue: |\n  -----BEGIN PRIVATE KEY-----\n  secret\n  -----END PRIVATE KEY-----\n")

    assert_equal [ "Ansible Vault content is not supported" ], vault.errors
    assert_equal [ "embedded private keys are not allowed" ], pem.errors
  end

  test "normalizes syntax failures and rejects multiple documents" do
    malformed = Subject.call("---\nvalue: [unterminated\n")
    multiple = Subject.call("---\none: 1\n---\ntwo: 2\n")

    assert_equal [ "is invalid YAML" ], malformed.errors
    assert_equal [ "must contain exactly one YAML document" ], multiple.errors
  end

  test "enforces depth and node limits" do
    nested = "leaf"
    (ControlCenter::Ansible::YamlLimits::MAX_DEPTH + 1).times { nested = [ nested ] }
    too_deep = Subject.call(JSON.generate(nested))
    too_many = Subject.call(JSON.generate(Array.new(ControlCenter::Ansible::YamlLimits::MAX_NODES, 0)))

    assert_equal [ "exceeds the maximum depth of 30" ], too_deep.errors
    assert_equal [ "exceeds the maximum node count of 10000" ], too_many.errors
  end

  test "rejects extreme syntax nesting before Psych recursively materializes it" do
    source = ("[" * 2_000) + "0" + ("]" * 2_000)

    result = Subject.call(source)

    assert_equal [ "exceeds the maximum depth of 30" ], result.errors
  end
end
