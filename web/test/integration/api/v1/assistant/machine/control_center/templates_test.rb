require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::TemplatesTest < ActionDispatch::IntegrationTest
  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "cc-templates-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
  end

  test "list_templates returns a bounded projection ordered by name" do
    template(name: "zzz-probe", kind: "cmdscript", commands: [ { "command" => "curl", "args" => [] } ])
    template(name: "aaa-probe", kind: "workflow", commands: [ { "command" => "curl", "args" => [] } ])

    get "/api/v1/assistant/machine/control_center/templates", headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 2, body["count"]
    names = body["items"].map { |i| i["name"] }
    assert_equal %w[aaa-probe zzz-probe], names
    item = body["items"].first
    assert_equal %w[id name kind description tags lock_version created_by updated_at], item.keys
  end

  test "list_templates is refused without the control_center_templates scope" do
    grant = read_grant
    Assistant::TurnGrant.order(:id).last.update_column(:read_scopes, [])

    get "/api/v1/assistant/machine/control_center/templates", headers: headers(grant)

    assert_response :forbidden
    assert_equal "scope_not_allowed", response.parsed_body["reason"]
  end

  test "list_templates narrows by the kind filter" do
    template(name: "a", kind: "cmdscript", commands: [ { "command" => "curl", "args" => [] } ])
    template(name: "b", kind: "workflow", commands: [ { "command" => "curl", "args" => [] } ])

    get "/api/v1/assistant/machine/control_center/templates", params: { kind: "workflow" }, headers: headers(read_grant)

    assert_response :success
    body = response.parsed_body
    assert_equal 1, body["count"]
    assert_equal "b", body["items"].first["name"]
  end

  test "get_template returns the full projection with authoring metadata" do
    record = template(
      name: "probe", kind: "cmdscript", description: "d", output: "json", tags: %w[recon],
      commands: [{ "command" => "curl", "args" => [ "-silent" ], "operator" => "" }],
      target: { "type" => "host" }, created_by: "someone"
    )

    get "/api/v1/assistant/machine/control_center/templates/#{record.id}", headers: headers(read_grant)

    assert_response :success
    result = response.parsed_body["template"]
    expected_keys = %w[id name kind description tags lock_version created_by updated_at output commands target created_at]
    assert_equal expected_keys, result.keys
    assert_equal "probe", result["name"]
    assert_equal "json", result["output"]
    assert_equal "someone", result["created_by"]
    assert_equal 0, result["lock_version"]
    assert_equal({ "type" => "host", "separator" => nil, "output" => nil }, result["target"])
    assert_equal %w[command args operator], result["commands"].first.keys
  end

  test "get_template closes nested records and removes secret material" do
    record = template(
      name: "probe", description: "api_key=do-not-return", tags: [ "safe", "token=do-not-return" ],
      commands: [ {
        "command" => "curl", "args" => [ "-silent", "Authorization: Bearer do-not-return" ],
        "operator" => "", "credential" => "do-not-return"
      } ],
      target: { "type" => "host", "separator" => "token=do-not-return", "unknown" => "do-not-return" }
    )

    get "/api/v1/assistant/machine/control_center/templates/#{record.id}", headers: headers(read_grant)

    assert_response :success
    result = response.parsed_body["template"]
    refute_includes response.body, "do-not-return"
    assert_equal "[REDACTED]", result["description"]
    assert_equal [ "safe", "[REDACTED]" ], result["tags"]
    assert_equal %w[command args operator], result["commands"].first.keys
    assert_equal %w[type separator output], result["target"].keys
  end

  test "get_template releases the reservation on a miss" do
    get "/api/v1/assistant/machine/control_center/templates/999999999", headers: headers(read_grant)

    assert_response :not_found
    assert_equal 0, Assistant::TurnGrant.order(:id).last.reload.reserved_bytes
  end

  private

  def template(name:, kind: "cmdscript", description: "d", output: nil, tags: [], commands: [], target: nil, created_by: nil)
    ::ControlCenter::Template.create!(
      name: name, kind: kind, description: description, output: output,
      tags: tags, commands: commands, target: target, created_by: created_by
    )
  end

  def read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_templates", "get_template" ]
    )
  end

  def headers(grant)
    { "Authorization" => "Bearer #{@service_token}", "X-Hunter-Turn-Grant" => grant }
  end
end
