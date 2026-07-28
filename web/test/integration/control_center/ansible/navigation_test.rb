require "test_helper"

class ControlCenter::Ansible::NavigationTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "every Ansible authoring page requires authentication" do
    [
      control_center_ansible_root_path,
      control_center_ansible_playbooks_path,
      control_center_ansible_inventories_path,
      control_center_ansible_variable_sets_path,
      control_center_ansible_runs_path
    ].each do |path|
      get path
      assert_redirected_to new_session_path
    end
  end

  test "the Control Center department has one Ansible tab active on descendants" do
    sign_in_as(@user)
    get control_center_ansible_inventories_path

    assert_response :success
    assert_select "nav[aria-label='Control Center sections'] a[href=?]", control_center_ansible_root_path,
      text: "Ansible", count: 1
    assert_select "nav[aria-label='Control Center sections'] a[href=?][aria-current=page]",
      control_center_ansible_root_path, text: "Ansible"
  end

  test "every page renders the four-link Ansible navigation with the correct active item" do
    sign_in_as(@user)
    pages = {
      control_center_ansible_root_path => "Playbooks",
      control_center_ansible_playbooks_path => "Playbooks",
      control_center_ansible_inventories_path => "Inventories",
      control_center_ansible_variable_sets_path => "Variable Sets",
      control_center_ansible_runs_path => "Runs"
    }

    pages.each do |path, active_label|
      get path
      assert_response :success
      assert_select "nav[aria-label='Ansible sections'] a", count: 4
      assert_select "nav[aria-label='Ansible sections'] a[aria-current=page]", text: active_label, count: 1
    end
  end
end
