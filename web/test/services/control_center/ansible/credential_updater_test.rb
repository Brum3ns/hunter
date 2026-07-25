require "test_helper"

class ControlCenter::Ansible::CredentialUpdaterTest < ActiveSupport::TestCase
  setup do
    @credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "old", become_password: "old-sudo", created_by: users(:one)
    )
  end

  test "blank secret retains the current value" do
    update(ssh_password: "", become_password: "")

    assert_equal "old", @credential.ssh_password
    assert_equal "old-sudo", @credential.become_password
  end

  test "nonblank secret replaces and explicit clear removes" do
    update(ssh_password: "new", clear_become_password: "1")

    assert_equal "new", @credential.ssh_password
    assert_nil @credential.become_password
  end

  test "explicit clear wins when a secret value is also present" do
    update(ssh_password: "should-not-win", clear_ssh_password: true, auth_type: "private_key",
      private_key: valid_private_key)

    assert_nil @credential.ssh_password
  end

  test "returns the unsaved credential with public attributes assigned" do
    result = ControlCenter::Ansible::CredentialUpdater.call(
      credential: @credential,
      attributes: { name: "renamed", username: "ops", ignored: "value" }
    )

    assert_same @credential, result
    assert_equal "renamed", result.name
    assert_equal "ops", result.username
    assert result.changed?
  end

  private

  def update(**attributes)
    ControlCenter::Ansible::CredentialUpdater.call(
      credential: @credential, attributes: attributes
    )
    @credential.save!
  end

  def valid_private_key
    OpenSSL::PKey::RSA.new(1024).to_pem
  end
end
