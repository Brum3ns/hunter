require "test_helper"

class ControlCenter::Ansible::CredentialTest < ActiveSupport::TestCase
  setup { @user = users(:one) }

  test "password secrets are encrypted in the raw database row" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers-password", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", become_password: "sudo-secret", created_by: @user
    )

    row = ActiveRecord::Base.connection.select_one(<<~SQL)
      SELECT ssh_password, become_password
      FROM control_center_ansible_credentials
      WHERE id = #{credential.id.to_i}
    SQL
    refute_includes row.fetch("ssh_password"), "fleet-secret"
    refute_includes row.fetch("become_password"), "sudo-secret"
    assert_equal "fleet-secret", credential.reload.ssh_password
  end

  test "requires the secret matching its authentication type" do
    password = ControlCenter::Ansible::Credential.new(name: "p", auth_type: "password", username: "a")
    refute password.valid?
    assert_includes password.errors[:ssh_password], "must be configured"

    key = ControlCenter::Ansible::Credential.new(name: "k", auth_type: "private_key", username: "a")
    refute key.valid?
    assert_includes key.errors[:private_key], "must be configured"
  end

  test "configured flags do not expose values" do
    credential = ControlCenter::Ansible::Credential.new(
      private_key: "secret", private_key_passphrase: "phrase", become_password: "sudo"
    )

    assert credential.private_key_configured?
    assert credential.private_key_passphrase_configured?
    assert credential.become_password_configured?
    refute credential.ssh_password_configured?
  end

  test "creator cannot be destroyed while credentials still reference it" do
    ControlCenter::Ansible::Credential.create!(
      name: "workers-password", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", created_by: @user
    )

    refute @user.destroy
    assert_includes @user.errors[:base], "Cannot delete record because dependent control center ansible credentials exist"
  end

  test "validates a stored private key when authentication switches to private key" do
    credential = ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "fleet-secret", private_key: "broken", created_by: @user
    )

    credential.auth_type = "private_key"

    refute credential.valid?
    assert_includes credential.errors[:private_key], "is invalid or its passphrase is incorrect"
  end
end
