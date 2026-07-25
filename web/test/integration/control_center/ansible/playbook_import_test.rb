require "test_helper"

class ControlCenter::Ansible::PlaybookImportTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    get control_center_ansible_root_path
  end

  test "mounts one importer for picker and stable page-wide drag and drop" do
    assert_response :success
    assert_select "section[data-controller~='ansible-playbook-import']" \
                  "[data-ansible-playbook-import-index-url-value=?]" \
                  "[data-ansible-playbook-import-validate-url-value=?]" \
                  "[data-ansible-playbook-import-max-files-value='100']" \
                  "[data-ansible-playbook-import-max-file-bytes-value='262144']" \
                  "[data-ansible-playbook-import-max-batch-bytes-value='10485760']",
                  api_v1_control_center_ansible_playbooks_path,
                  validate_api_v1_control_center_ansible_playbooks_path

    assert_select "input[type=file][multiple][data-ansible-playbook-import-target=fileInput]" do |inputs|
      assert_includes inputs.first["data-action"], "ansible-playbook-import#filesSelected"
    end

    section = css_select("section[data-controller~='ansible-playbook-import']").first
    actions = section["data-action"].split
    assert_includes actions, "dragenter@window->ansible-playbook-import#dragEnter"
    assert_includes actions, "dragover@window->ansible-playbook-import#dragOver"
    assert_includes actions, "dragleave@window->ansible-playbook-import#dragLeave"
    assert_includes actions, "drop@window->ansible-playbook-import#drop"
    assert_includes actions, "dragend@window->ansible-playbook-import#dragEnd"
    assert_select "[data-ansible-playbook-import-target=dropOverlay]", text: /Drop YAML playbooks to import/
  end

  test "renders progress, summary, and all four conflict decisions" do
    assert_select "dialog[data-ansible-playbook-import-target=dialog]" do
      assert_select "[data-ansible-playbook-import-target=rows]"
      assert_select "[data-ansible-playbook-import-target=summary]"
      assert_select "button[data-ansible-playbook-import-target=close][data-action='ansible-playbook-import#close']"
      assert_select "[data-ansible-playbook-import-target=conflictPanel]" do
        %w[update update_all skip skip_all].each do |decision|
          assert_select "button[data-decision='#{decision}'][data-action='ansible-playbook-import#chooseConflict']", count: 1
        end
      end
    end
  end
end
