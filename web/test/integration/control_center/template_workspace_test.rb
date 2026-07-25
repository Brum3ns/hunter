require "test_helper"

class ControlCenter::TemplateWorkspaceTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    get control_center_root_path
  end

  test "renders a permanent editor above a separately scrolling library" do
    assert_response :success
    assert_select "[data-template-workspace]" do
      assert_select "[data-template-editor-pane][data-control-center-templates-target=editor]:not(.hidden)", count: 1
      assert_select "[data-template-library-pane]", count: 1
      assert_select "[data-template-library-scroll]", count: 1
    end
    assert_operator response.body.index("data-template-editor-pane"), :<,
                    response.body.index("data-template-library-pane")
  end

  test "renders template dork search controls and distinct list states" do
    assert_select "input[type=search][data-control-center-templates-target=searchInput]" do |inputs|
      actions = inputs.first["data-action"].split
      assert_includes actions, "input->control-center-templates#searchChanged"
      assert_includes actions, "search->control-center-templates#searchChanged"
    end
    assert_select "button[data-control-center-templates-target=clearSearch][data-action='control-center-templates#clearSearch']"
    assert_select "[data-control-center-templates-target=resultCount]"
    assert_select "[data-control-center-templates-target=listError]"
    assert_select "[data-control-center-templates-target=empty]", text: /No templates yet/
    assert_select "[data-control-center-templates-target=noMatches]", text: /No templates match/
    assert_select "button[aria-label='Template search syntax help']"
  end

  test "wires editor-wide dirty tracking without hiding the editor" do
    editor = css_select("[data-control-center-templates-target=editor]").first
    refute_nil editor
    refute_includes editor["class"].split, "hidden"
    actions = editor["data-action"].split
    assert_includes actions, "input->control-center-templates#markEditorDirty"
    assert_includes actions, "change->control-center-templates#markEditorDirty"
  end

  test "keeps permanent-editor actions available" do
    assert_select "button[data-action='control-center-templates#newTemplate']", text: /New template/
    assert_select "button[data-action='control-center-templates#save']", text: /^\s*Save\s*$/
    assert_select "button[data-action='control-center-templates#saveAndClose']", text: /Save & close/
    assert_select "button[data-action='control-center-templates#closeEditor']", text: /Cancel/
  end
end
