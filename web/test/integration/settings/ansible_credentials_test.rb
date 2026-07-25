require "test_helper"

class Settings::AnsibleCredentialsTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "requires authentication" do
    post settings_ansible_credentials_path, params: { ansible_credential: { name: "x" } }

    assert_redirected_to new_session_path
  end

  test "settings renders the credential section and write-only fields" do
    ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "never-render-me", become_password: "sudo-secret", created_by: @user
    )
    sign_in_as(@user)

    get settings_path

    assert_response :success
    assert_select "a[href='#ansible-credentials']", text: "Ansible credentials"
    assert_select "section#ansible-credentials h2", text: "Ansible credentials"
    assert_select "details", text: /Edit workers/
    refute_includes response.body, "never-render-me"
    refute_includes response.body, "sudo-secret"
  end

  test "creates a password credential and never renders its value" do
    sign_in_as(@user)
    post settings_ansible_credentials_path, params: {
      ansible_credential: {
        name: "workers", auth_type: "password", username: "ansible",
        ssh_password: "never-render-me"
      }
    }

    assert_redirected_to settings_path(anchor: "ansible-credentials")
    follow_redirect!
    assert_response :success
    assert_includes response.body, "workers"
    refute_includes response.body, "never-render-me"
  end

  test "blank update retains a secret" do
    credential = password_credential
    sign_in_as(@user)

    patch settings_ansible_credential_path(credential), params: {
      ansible_credential: {
        name: "workers", auth_type: "password", username: "ops", ssh_password: ""
      }
    }

    assert_redirected_to settings_path(anchor: "ansible-credentials")
    assert_equal "old", credential.reload.ssh_password
    assert_equal "ops", credential.username
  end

  test "clearing the required authentication secret is rejected" do
    credential = password_credential
    sign_in_as(@user)

    patch settings_ansible_credential_path(credential), params: {
      ansible_credential: {
        name: "workers", auth_type: "password", username: "ansible",
        clear_ssh_password: "1"
      }
    }

    assert_redirected_to settings_path(anchor: "ansible-credentials")
    assert_match(/Ssh password must be configured/, flash[:alert])
    assert_equal "old", credential.reload.ssh_password
  end

  test "deletes a credential" do
    credential = password_credential
    sign_in_as(@user)

    assert_difference -> { ControlCenter::Ansible::Credential.count }, -1 do
      delete settings_ansible_credential_path(credential)
    end
    assert_redirected_to settings_path(anchor: "ansible-credentials")
  end

  private

  def password_credential
    ControlCenter::Ansible::Credential.create!(
      name: "workers", auth_type: "password", username: "ansible",
      ssh_password: "old", created_by: @user
    )
  end
end
