require "test_helper"
require "zip"

class Api::V1::ControlCenter::Ansible::PlaybooksTest < ActionDispatch::IntegrationTest
  YAML = "---\n- hosts: workers\n  tasks: []\n"

  setup { @user = users(:one) }

  test "requires authentication and the control center bearer scope" do
    get "/api/v1/control_center/ansible/playbooks"
    assert_response :unauthorized

    _token, raw = ApiToken.generate(user: @user, name: "cves-only", scopes: [ "cves" ])
    get "/api/v1/control_center/ansible/playbooks", headers: { "Authorization" => "Bearer #{raw}" }

    assert_response :forbidden
    assert_equal "insufficient_scope", JSON.parse(response.body)["error"]
  end

  test "session CRUD serializes content metadata and ordered variable set ids" do
    first = variable_set("First")
    second = variable_set("Second")
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/playbooks", params: {
      name: "Baseline", description: "Worker baseline", yaml_content: YAML,
      variable_set_ids: [ second.id, first.id ], checksum: "forged", created_by_id: users(:two).id
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal %w[checksum created_at description id name updated_at variable_set_ids yaml_content], body.keys.sort
    assert_equal [ second.id, first.id ], body["variable_set_ids"]
    assert_equal Digest::SHA256.hexdigest(YAML), body["checksum"]
    playbook = ControlCenter::Ansible::Playbook.find(body["id"])
    assert_equal @user, playbook.created_by

    get "/api/v1/control_center/ansible/playbooks"
    assert_response :success
    assert_equal body["id"], JSON.parse(response.body).fetch("playbooks").sole["id"]

    get "/api/v1/control_center/ansible/playbooks/#{body["id"]}"
    assert_response :success
    assert_equal "Baseline", JSON.parse(response.body)["name"]

    patch "/api/v1/control_center/ansible/playbooks/#{body["id"]}",
      params: { name: "Updated", variable_set_ids: [ first.id ] }, as: :json
    assert_response :success
    assert_equal [ first.id ], JSON.parse(response.body)["variable_set_ids"]

    delete "/api/v1/control_center/ansible/playbooks/#{body["id"]}"
    assert_response :no_content
    refute ControlCenter::Ansible::Playbook.exists?(body["id"])
  end

  test "a scoped bearer can create and update a playbook" do
    _token, raw = ApiToken.generate(user: @user, name: "control-center", scopes: [ "control_center" ])
    headers = { "Authorization" => "Bearer #{raw}" }

    post "/api/v1/control_center/ansible/playbooks",
      params: { name: "Bearer", yaml_content: YAML }, headers: headers, as: :json
    assert_response :created
    id = JSON.parse(response.body)["id"]

    patch "/api/v1/control_center/ansible/playbooks/#{id}",
      params: { description: "via token" }, headers: headers, as: :json
    assert_response :success
    assert_equal "via token", JSON.parse(response.body)["description"]
  end

  test "returns not found and model validation envelopes" do
    sign_in_as(@user)

    get "/api/v1/control_center/ansible/playbooks/0"
    assert_response :not_found

    post "/api/v1/control_center/ansible/playbooks",
      params: { name: "Unsafe", yaml_content: "---\n- hosts: workers\n  connection: local\n" }, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal "unprocessable_entity", body["error"]
    assert_includes body.dig("details", "yaml_content"), "connection: local is not allowed"
  end

  test "fast validation does not persist" do
    sign_in_as(@user)

    assert_no_difference -> { ControlCenter::Ansible::Playbook.count } do
      post "/api/v1/control_center/ansible/playbooks/validate",
        params: { yaml_content: YAML }, as: :json
    end

    assert_response :success
    assert_equal({ "valid" => true, "errors" => [] }, JSON.parse(response.body))
  end

  test "exports deduplicated selected playbooks in request order" do
    first = ControlCenter::Ansible::Playbook.create!(name: "First", yaml_content: YAML, created_by: @user)
    second_yaml = "---\n- hosts: second\n  tasks: []\n"
    second = ControlCenter::Ansible::Playbook.create!(name: "Second", yaml_content: second_yaml, created_by: @user)
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/playbooks/export",
      params: { ids: [ second.id, first.id, second.id ] }, as: :json

    assert_response :success
    assert_equal "application/zip", response.media_type
    assert_match(/hunter-ansible-playbooks-\d{8}T\d{6}Z\.zip/, response.headers["Content-Disposition"])
    Zip::File.open_buffer(StringIO.new(response.body)) do |zip|
      assert_equal [ "Second.yml", "First.yml" ], zip.map(&:name)
      assert_equal second_yaml, zip.read("Second.yml")
      assert_equal YAML, zip.read("First.yml")
    end
  end

  test "export rejects empty and excessive selections and returns not found for unknown ids" do
    sign_in_as(@user)

    post "/api/v1/control_center/ansible/playbooks/export", params: { ids: [] }, as: :json
    assert_response :unprocessable_entity

    post "/api/v1/control_center/ansible/playbooks/export",
      params: { ids: (1..101).to_a }, as: :json
    assert_response :unprocessable_entity

    post "/api/v1/control_center/ansible/playbooks/export", params: { ids: [ 0 ] }, as: :json
    assert_response :not_found
  end

  test "a scoped bearer can export playbooks without CSRF" do
    playbook = ControlCenter::Ansible::Playbook.create!(name: "Bearer", yaml_content: YAML, created_by: @user)
    _token, raw = ApiToken.generate(user: @user, name: "export", scopes: [ "control_center" ])

    post "/api/v1/control_center/ansible/playbooks/export",
      params: { ids: [ playbook.id ] },
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json

    assert_response :success
    assert_equal "application/zip", response.media_type
  end

  test "cookie export is CSRF protected" do
    playbook = ControlCenter::Ansible::Playbook.create!(name: "Cookie", yaml_content: YAML, created_by: @user)
    sign_in_as(@user)
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post "/api/v1/control_center/ansible/playbooks/export",
      params: { ids: [ playbook.id ] }, as: :json

    assert_response :forbidden
    assert_equal "invalid_csrf_token", JSON.parse(response.body)["error"]
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "export closes and unlinks its temporary archive after the response body is consumed" do
    playbook = ControlCenter::Ansible::Playbook.create!(name: "Cleanup", yaml_content: YAML, created_by: @user)
    sign_in_as(@user)
    archive = ControlCenter::Ansible::PlaybookArchive.call([ playbook ])
    path = archive.path

    stub_methods(ControlCenter::Ansible::PlaybookArchive, call: ->(_playbooks) { archive }) do
      post "/api/v1/control_center/ansible/playbooks/export", params: { ids: [ playbook.id ] }, as: :json
      assert_response :success
      response.body
    end

    refute File.exist?(path)
  ensure
    archive&.close!
  end

  private

  def variable_set(name)
    ControlCenter::Ansible::VariableSet.create!(name: name, created_by: @user)
  end
end
