require "test_helper"

class ControlCenter::TemplateImportTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    get control_center_root_path
  end

  test "renders a list-level multiple YAML picker" do
    assert_response :success
    assert_select "label", text: /Import YAML/
    assert_select "input[type=file][multiple][data-control-center-templates-target=batchFileInput]" do |inputs|
      input = inputs.first
      assert_includes input["accept"], ".yaml"
      assert_includes input["accept"], ".yml"
      assert_includes input["data-action"], "control-center-templates#batchFilesSelected"
    end
  end

  test "wires page-wide file drag and drop" do
    section = css_select("section[data-controller~='control-center-templates']").first
    actions = section["data-action"].split
    assert_includes actions, "dragenter@window->control-center-templates#dragEnter"
    assert_includes actions, "dragover@window->control-center-templates#dragOver"
    assert_includes actions, "dragleave@window->control-center-templates#dragLeave"
    assert_includes actions, "drop@window->control-center-templates#dropFiles"
    assert_includes actions, "dragend@window->control-center-templates#dragEnd"
    assert_select "[data-control-center-templates-target=dropOverlay]", text: /Drop YAML templates to import/
  end

  test "renders progress and all conflict decisions" do
    assert_select "dialog[data-control-center-templates-target=importDialog]" do
      assert_select "[data-control-center-templates-target=importRows]"
      assert_select "[data-control-center-templates-target=importSummary]"
      assert_select "button[data-control-center-templates-target=importClose][data-action='control-center-templates#closeImport']"
      assert_select "[data-control-center-templates-target=conflictPanel]" do
        %w[update update_all skip skip_all].each do |decision|
          assert_select "button[data-decision='#{decision}'][data-action='control-center-templates#chooseImportConflict']", count: 1
        end
      end
    end
  end
end
