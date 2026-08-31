require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::Ansible::PlaybookExportsTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "playbook-export-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
    @playbook = ControlCenter::Ansible::Playbook.create!(
      name: "exported", yaml_content: "---\n- hosts: all\n  tasks: []\n", created_by: machine_user
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "returns only a short-lived human-owned browser reference" do
    post "/api/v1/assistant/machine/control_center/ansible/playbooks/export",
      params: { ids: [ @playbook.id ] }, headers: machine_headers, as: :json

    assert_response :created
    receipt = response.parsed_body.fetch("receipt")
    artifact = Assistant::ExportArtifact.find(receipt.dig("target", "id"))
    metadata = receipt.fetch("artifact")
    assert_equal machine_user, artifact.user
    assert_equal artifact.byte_count, metadata.fetch("byte_count")
    assert_match %r{\A/assistant/exports/}, metadata.fetch("browser_download_reference")
    refute response.body.include?(artifact.payload)
    refute response.body.include?(artifact.payload.unpack1("H*"))
    refute response.body.include?("tmp")

    get metadata.fetch("browser_download_reference")
    assert_response :redirect

    sign_in_as(machine_user)
    get metadata.fetch("browser_download_reference")
    assert_response :success
    assert_equal "application/zip", response.media_type
    assert response.body.start_with?("PK")
  end

  test "rejects unbounded and missing selections without an artifact" do
    assert_no_difference "Assistant::ExportArtifact.count" do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks/export",
        params: { ids: [] }, headers: machine_headers, as: :json
    end
    assert_response :unprocessable_content

    assert_no_difference "Assistant::ExportArtifact.count" do
      post "/api/v1/assistant/machine/control_center/ansible/playbooks/export",
        params: { ids: [ 99_999_999 ] }, headers: machine_headers, as: :json
    end
    assert_response :not_found
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def machine_headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
