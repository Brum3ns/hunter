require "test_helper"

class Api::V1::ControlCenter::TemplatesYamlTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "validate_yaml reports valid for a good template" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "name: probe\ncommands:\n  - command: httpx\n    args: [-silent]\n" }, as: :json
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["valid"]
    assert_empty body["errors"]
    assert_equal "probe", body["template"]["name"]
  end

  test "a retired allowlist value cannot narrow YAML validation" do
    sign_in_as(@user)
    original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

    post "/api/v1/control_center/templates/validate_yaml",
      params: { yaml: "name: nuclei-crlf\ncommands:\n  - command: nuclei\n    args: [-tags, crlf]\n" },
      as: :json

    assert_response :success
    assert_equal true, response.parsed_body["valid"]
    assert_empty response.parsed_body["errors"]
  ensure
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
  end

  test "validate_yaml accepts any command by default" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "name: ok\ncommands:\n  - command: nmap\n    args: [-sV, __TARGET_FILE__]\n" }, as: :json
    assert_response :success
    assert_equal true, JSON.parse(response.body)["valid"]
  end

  test "validate_yaml rejects malicious YAML without persisting" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates/validate_yaml",
         params: { yaml: "--- !ruby/object:Kernel {}" }, as: :json
    assert_response :success
    assert_equal false, JSON.parse(response.body)["valid"]
    assert_equal 0, ControlCenter::Template.count
  end

  test "create via yaml persists a valid template" do
    sign_in_as(@user)
    post "/api/v1/control_center/templates",
         params: { yaml: "name: fromyaml\ncommands:\n  - command: httpx\n    args: [-silent]\n" }, as: :json
    assert_response :created
    assert ControlCenter::Template.exists?(name: "fromyaml")
  end

  test "create via yaml persists a custom command with placeholders and a target" do
    sign_in_as(@user)
    yaml = "name: custom\n" \
           "commands:\n  - command: nmap\n    args: [-sV, -iL, __TARGET_FILE__, -oJ, /tmp/out.json]\n" \
           "target:\n  type: file\n  separator: \"\\n\"\n  output: targets.txt\n"
    post "/api/v1/control_center/templates", params: { yaml: yaml }, as: :json
    assert_response :created
    assert ControlCenter::Template.exists?(name: "custom")
  end

  test "create via YAML persists an arbitrary command despite a retired allowlist value" do
    sign_in_as(@user)
    original = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"

    post "/api/v1/control_center/templates",
      params: { yaml: "name: unrestricted-bash\ncommands:\n  - command: bash\n    args: [-c, 'printf ok']\n" },
      as: :json

    assert_response :created
    assert_equal "bash", ControlCenter::Template.find_by!(name: "unrestricted-bash").commands.first.fetch("command")
  ensure
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = original
  end

  test "serialize includes rendered yaml" do
    sign_in_as(@user)
    t = ControlCenter::Template.create!(name: "ser", commands: [{ "command" => "httpx", "args" => ["-silent"], "operator" => "" }])
    get "/api/v1/control_center/templates/#{t.id}"
    assert_response :success
    assert_includes JSON.parse(response.body)["yaml"], "httpx"
  end
end
