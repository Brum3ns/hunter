require "test_helper"

class Assistant::Context::SerializersTest < ActiveSupport::TestCase
  test "program serializer emits only bounded plain-text fields" do
    program = Program.new(
      "_sid" => "bugcrowd-acme",
      "name" => "<b>Acme</b>",
      "platform" => "bugcrowd",
      "status" => "open",
      "public" => true,
      "bounty" => true,
      "currency" => "USD",
      "tags" => [ "web" ],
      "languages" => [ "English" ],
      "description" => "<p>Public policy</p>",
      "policy" => { "vpn_ips" => [ "10.0.0.1" ] },
      "api_token" => "must-not-leak"
    )

    result = Assistant::Context::Catalog.serialize!(type: "program", record: program)

    assert_equal %i[bounty currency description languages name platform public sid status tags],
      result.fetch(:data).keys.sort
    assert_equal "Acme", result.dig(:data, :name)
    assert_equal "Public policy", result.dig(:data, :description)
    refute_includes result.to_json, "10.0.0.1"
    refute_includes result.to_json, "must-not-leak"
  end

  test "target serializer strips URL credentials query fragment headers and raw attributes" do
    target = Target.new(
      "id" => "a",
      "target" => {
        "url" => "https://u:p@example.test/x?token=s#f",
        "host" => "example.test",
        "port" => 443,
        "scheme" => "https",
        "path" => "/x",
        "method" => "GET"
      },
      "http" => { "status_code" => 200, "title" => "Home", "webserver" => "nginx" },
      "metadata" => { "program" => "acme" },
      "tech" => [ "Rails" ],
      "headers" => { "authorization" => "Bearer secret" },
      "raw_response" => "private"
    )

    result = Assistant::Context::Catalog.serialize!(type: "target", record: target)

    assert_equal "https://example.test/x", result.dig(:data, :url)
    refute_includes result.to_json, "Bearer"
    refute_includes result.to_json, "token="
    refute result[:data].key?(:headers)
    refute result[:data].key?(:raw_response)
  end

  test "CVE and vulnerability serializers omit details PoC and unknown sections" do
    cve = Cve.new(
      "id" => "CVE-2026-1",
      "summary" => "Summary",
      "severity_level" => "high",
      "details" => "large secret details",
      "chain" => { "root" => [ "CWE-79" ] },
      "internal" => "no"
    )
    vulnerability = Vulnerability.new(
      "id" => "v1",
      "metadata" => { "program" => "acme", "tool" => "nuclei", "date" => "2026-01-01", "token" => "no" },
      "report" => { "title" => "XSS", "status" => "new", "private" => "no" },
      "finding" => { "name" => "Reflected XSS", "type" => "xss", "severity" => "high" },
      "target" => { "host" => "example.test", "url" => "https://example.test/x?q=s", "method" => "GET" },
      "poc" => { "request" => "secret exploit" }
    )

    cve_result = Assistant::Context::Catalog.serialize!(type: "cve", record: cve)
    vuln_result = Assistant::Context::Catalog.serialize!(type: "vulnerability", record: vulnerability)

    refute_includes cve_result.to_json, "large secret details"
    refute_includes cve_result.to_json, "internal"
    assert_equal({ root: [ "CWE-79" ] }, cve_result.dig(:data, :chain))
    refute_includes vuln_result.to_json, "secret exploit"
    refute_includes vuln_result.to_json, "private"
    assert_equal "https://example.test/x", vuln_result.dig(:data, :target, :url)
  end

  test "template and playbook serializers emit exact authoring fields" do
    template = ControlCenter::Template.create!(
      name: "Probe", kind: "cmdscript", tags: [ "web" ], description: "Safe",
      output: "json", commands: [ { command: "httpx", args: [ "-silent" ], operator: "" } ],
      target: "__TARGET_FILE__", created_by: "one"
    )
    playbook = ControlCenter::Ansible::Playbook.create!(
      name: "Probe", description: "Safe", yaml_content: "- hosts: all\n  tasks: []\n",
      created_by: users(:one)
    )

    template_data = Assistant::Context::Catalog.serialize!(
      type: "whiterabbit_template", record: template
    ).fetch(:data)
    playbook_data = Assistant::Context::Catalog.serialize!(
      type: "ansible_playbook", record: playbook
    ).fetch(:data)

    assert_equal %i[commands description id kind name output tags target updated_at], template_data.keys.sort
    assert_equal %i[checksum description id name updated_at yaml], playbook_data.keys.sort
    refute_includes playbook_data.keys, :variable_sets
    refute_includes template_data.keys, :created_by
  end

  test "artifact examples containing secret patterns fail closed" do
    cases = YAML.safe_load_file(
      Rails.root.join("test/fixtures/files/assistant_adversarial_contexts.yml")
    )

    cases.fetch("template_args").each do |value|
      template = ControlCenter::Template.new(
        name: SecureRandom.hex(4), kind: "cmdscript",
        commands: [ { command: "httpx", args: [ value ], operator: "" } ]
      )
      assert_raises(Assistant::Context::Catalog::UnsafeContentError) do
        Assistant::Context::Catalog.serialize!(type: "whiterabbit_template", record: template)
      end
    end

    cases.fetch("playbooks").each do |yaml|
      playbook = ControlCenter::Ansible::Playbook.new(
        name: SecureRandom.hex(4), yaml_content: yaml, created_by: users(:one)
      )
      assert_raises(Assistant::Context::Catalog::UnsafeContentError) do
        Assistant::Context::Catalog.serialize!(type: "ansible_playbook", record: playbook)
      end
    end
  end

  test "catalog rejects unknown types and serialized output over 32 KiB" do
    assert_raises(KeyError) do
      Assistant::Context::Catalog.serialize!(type: "unknown", record: Object.new)
    end

    program = Program.new("_sid" => "large", "name" => "Large", "description" => "x" * 40_000)
    assert_raises(Assistant::Context::Catalog::TooLargeError) do
      Assistant::Context::Catalog.serialize!(type: "program", record: program)
    end
  end
end
