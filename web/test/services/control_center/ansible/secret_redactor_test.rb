require "test_helper"

class ControlCenter::Ansible::SecretRedactorTest < ActiveSupport::TestCase
  test "defines the recursive secret redactor" do
    assert defined?(ControlCenter::Ansible::SecretRedactor), "expected SecretRedactor to be defined"
  end

  test "redacts exact secret substrings recursively without mutating input" do
    input = {
      "abcdef" => "abcdef then abc",
      "prefix-abc" => [ "safe", { "nested" => "xabcdefy" } ]
    }
    original = Marshal.load(Marshal.dump(input))

    result = ControlCenter::Ansible::SecretRedactor.call(input, secrets: [ "abc", "", "abcdef" ])

    assert_equal original, input
    assert_equal(
      {
        "[FILTERED]" => "[FILTERED] then [FILTERED]",
        "prefix-abc" => [ "safe", { "nested" => "x[FILTERED]y" } ]
      },
      result.value
    )
    refute result.truncated
    assert_operator result.bytes, :>, 0
  end

  test "preserves primitives and ignores duplicate empty secrets" do
    result = ControlCenter::Ansible::SecretRedactor.call(false, secrets: [ nil, "", "" ])

    assert_equal false, result.value
    refute result.truncated
    assert_equal JSON.generate(false).bytesize, result.bytes
  end

  test "caps an oversized serialized value with its beginning and ending" do
    source = "A" * 60.kilobytes + "B" * 40.kilobytes

    result = ControlCenter::Ansible::SecretRedactor.call(source, secrets: [])

    assert result.truncated
    assert_operator result.bytes, :<=, ControlCenter::Ansible::SecretRedactor::MAX_BYTES
    assert result.value.start_with?("A" * 100)
    assert result.value.end_with?("B" * 100)
    assert_includes result.value, "\n...[TRUNCATED]...\n"
  end
end
