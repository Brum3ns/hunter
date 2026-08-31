require "test_helper"

class Api::V1::Assistant::Machine::ControlCenter::OperationsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @original_config_enabled = Assistant::Config.method(:enabled?)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = users(:one).username
    Assistant::Config.define_singleton_method(:enabled?) { |*, **| true }
    Assistant::Setting.instance.enable!
    Assistant::Setting.instance.update!(control_center_write_enabled: true)
    _identity, @service_token = Assistant::ServiceIdentity.generate!(
      name: "control-center-operations-#{SecureRandom.hex(4)}", role: "mcp_reader"
    )
  end

  teardown do
    Assistant::Config.define_singleton_method(:enabled?, @original_config_enabled)
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "validates a structured Whiterabbit template without persisting it" do
    body = { template: {
      name: "nuclei-safe", kind: "cmdscript", description: "safe",
      commands: [ { command: "nuclei", args: [ "-silent" ], operator: "" } ]
    } }
    assert_no_difference -> { ControlCenter::Template.count } do
      post "/api/v1/assistant/machine/control_center/templates/validate",
        params: body, headers: headers, as: :json
    end

    assert_response :success
    assert_equal true, response.parsed_body.fetch("valid")
    assert_equal [], response.parsed_body.fetch("codes")
  end

  test "resolves target selections without submitting a job" do
    selections = [ { source: "targets", q: "program:acme", ids: [], exclude_ids: [] } ]
    stub_methods(ControlCenter::TargetSelection, validate!: true, count: 57, sample: [ "a.example.test" ]) do
      assert_no_difference -> { ControlCenter::Job.count } do
        post "/api/v1/assistant/machine/control_center/jobs/resolve_targets",
          params: { selections: selections, targets: [] },
          headers: headers, as: :json
      end
    end

    assert_response :success
    assert_equal 57, response.parsed_body.fetch("count")
    assert_equal [ "a.example.test" ], response.parsed_body.fetch("sample")
  end

  test "submits a validated Whiterabbit job with a launch receipt" do
    template = ControlCenter::Template.create!(
      name: "unrestricted-submit", kind: "cmdscript",
      commands: [ { "command" => "bash", "args" => [ "-c", "printf ok" ], "operator" => "" } ]
    )
    body = { template: template.name, queue_name: "test", targets: [ "a.example.test" ],
      selections: [], target_chunk: 10, delay: 0 }

    assert_enqueued_with(job: ControlCenter::SubmitJob) do
      post "/api/v1/assistant/machine/control_center/jobs", params: body,
        headers: headers, as: :json
    end

    assert_response :created
    job = ControlCenter::Job.order(:id).last
    assert_equal machine_user.username, job.created_by
    assert_equal "submit_whiterabbit_job", response.parsed_body.dig("receipt", "tool")
    assert_equal job.id.to_s, response.parsed_body.dig("receipt", "target", "id")
  end

  test "health output omits command detail and credentials" do
    health = {
      rabbitmq: { ok: false, detail: "amqp://user:password@rabbit" },
      mongo: { ok: true, detail: "mongodb://secret" }
    }
    stub_methods(ControlCenter::Standalone, health: health) do
      get "/api/v1/assistant/machine/control_center/health",
        headers: headers
    end

    assert_response :success
    assert_equal({ "rabbitmq" => { "ok" => false }, "mongo" => { "ok" => true } },
      response.parsed_body.fetch("health"))
    refute_includes response.body, "password"
    refute_includes response.body, "mongodb"
  end

  private

  def machine_user
    assistant_turns(:created).user
  end

  def headers(*)
    { "Authorization" => "Bearer #{@service_token}" }
  end
end
