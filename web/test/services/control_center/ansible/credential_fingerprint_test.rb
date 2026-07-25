require "test_helper"
require "openssl"

class ControlCenter::Ansible::CredentialFingerprintTest < ActiveSupport::TestCase
  Subject = ControlCenter::Ansible::CredentialFingerprint

  test "returns the OpenSSH SHA256 fingerprint for an encrypted key" do
    key = OpenSSL::PKey::RSA.new(2048)
    pem = key.export(OpenSSL::Cipher.new("aes-256-cbc"), "phrase")
    expected = Base64.strict_encode64(Digest::SHA256.digest(key.to_blob)).delete_suffix("=")

    result = Subject.call(private_key: pem, passphrase: "phrase")

    assert_equal "SHA256:#{expected}", result.fingerprint
    assert_nil result.error
  end

  test "normalizes an invalid-key failure" do
    result = Subject.call(private_key: "broken", passphrase: nil)

    assert_nil result.fingerprint
    assert_equal "is invalid or its passphrase is incorrect", result.error
  end

  test "normalizes an incorrect-passphrase failure" do
    key = OpenSSL::PKey::RSA.new(2048)
    pem = key.export(OpenSSL::Cipher.new("aes-256-cbc"), "right-phrase")

    result = Subject.call(private_key: pem, passphrase: "wrong-phrase")

    assert_nil result.fingerprint
    assert_equal "is invalid or its passphrase is incorrect", result.error
  end
end
