require "test_helper"

class Assistant::ConfirmedSaveTest < ActiveSupport::TestCase
  TEMPLATE_ATTRIBUTES = {
    "name" => "Assistant probe",
    "kind" => "cmdscript",
    "description" => "Review before saving",
    "commands" => [
      { "command" => "httpx", "args" => [ "-silent", "-l", "__TARGET_FILE__" ], "operator" => "" }
    ]
  }.freeze

  ANSIBLE_SOURCE = <<~YAML.freeze
    ---
    - name: Explain selection
      hosts: workers
      gather_facts: false
      tasks:
        - name: Report
          ansible.builtin.debug:
            msg: ready
  YAML

  setup do
    @user = users(:one)
    @original_command_allowlist = ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"]
    @original_ansible_allowlist = ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"]
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "httpx"
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = "ansible.builtin.debug"
  end

  teardown do
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = @original_command_allowlist
    ENV["ASSISTANT_ANSIBLE_MODULE_ALLOWLIST"] = @original_ansible_allowlist
  end

  test "creates a revalidated template and body-free audit without triggering execution" do
    draft = whiterabbit_draft
    result = nil

    assert_no_difference [
      -> { ControlCenter::Job.count },
      -> { ControlCenter::Ansible::Run.count },
      -> { ControlCenter::Ansible::ExecutorTask.count }
    ] do
      result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)

      assert result.success?, result.errors.inspect
      assert_predicate result.record, :persisted?
      assert_equal @user.username, result.record.created_by
    end

    audit = Assistant::AuditEvent.find_by!(event: "draft.confirmed_save", target_type: "whiterabbit_template")
    assert_equal result.record.id.to_s, audit.target_id
    assert_equal "whiterabbit_template", audit.resource_type
    assert_equal draft.validation_version, audit.resource_id
    assert_match(/\A\h{64}\z/, audit.content_hash)
    assert_equal draft.content_digest, audit.metadata.fetch("source")
    refute_includes audit.attributes.to_json, draft.content
    refute_includes audit.attributes.to_json, draft.name

    draft.reload
    assert_equal "whiterabbit_template", draft.destination_type
    assert_equal result.record.id.to_s, draft.destination_id
    assert_equal result.record.lock_version.to_s, draft.destination_lock_version

    assert_no_difference -> { ControlCenter::Template.count } do
      replay = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)
      refute replay.success?
      assert_includes replay.errors, "destination_mismatch"
    end
  end

  test "revalidates against the current command policy before persistence" do
    draft = whiterabbit_draft
    ENV["CONTROL_CENTER_COMMAND_ALLOWLIST"] = "nuclei"

    assert_no_difference -> { ControlCenter::Template.count } do
      result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)

      refute result.success?
      assert_includes result.errors, "validation_failed"
      assert_includes result.errors, "assistant_command_not_allowed"
    end
  end

  test "requires ownership and a valid result from the current validation version" do
    foreign = whiterabbit_draft(conversation: assistant_conversations(:other_user), turn: assistant_turns(:other_user))
    stale = whiterabbit_draft(validation_version: "old-version")

    result = Assistant::ConfirmedSave.call(draft: foreign, user: @user, destination: nil)
    refute result.success?
    assert_includes result.errors, "not_owner"

    result = Assistant::ConfirmedSave.call(draft: stale, user: @user, destination: nil)
    refute result.success?
    assert_includes result.errors, "validation_stale"
  end

  test "refuses an update when the destination changed after draft review" do
    destination = ControlCenter::Template.create!(TEMPLATE_ATTRIBUTES.merge("description" => "Original"))
    reviewed_version = destination.lock_version
    draft = whiterabbit_draft(
      destination_type: "whiterabbit_template",
      destination_id: destination.id.to_s,
      destination_lock_version: reviewed_version.to_s
    )
    destination.update!(description: "Changed elsewhere")

    result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: destination)

    refute result.success?
    assert_includes result.errors, "destination_stale"
    assert_equal "Changed elsewhere", destination.reload.description
  end

  test "a preloaded concurrent confirmation cannot consume the first save's new lock version" do
    destination = ControlCenter::Template.create!(TEMPLATE_ATTRIBUTES.merge("description" => "Original"))
    draft = whiterabbit_draft(
      destination_type: "whiterabbit_template",
      destination_id: destination.id.to_s,
      destination_lock_version: destination.lock_version.to_s
    )
    first_request_draft = Assistant::Draft.find(draft.id)
    second_request_draft = Assistant::Draft.find(draft.id)
    first_destination = ControlCenter::Template.find(destination.id)
    second_destination = ControlCenter::Template.find(destination.id)

    first = Assistant::ConfirmedSave.call(
      draft: first_request_draft, user: @user, destination: first_destination
    )
    assert first.success?, first.errors.inspect
    saved_version = destination.reload.lock_version

    second = Assistant::ConfirmedSave.call(
      draft: second_request_draft, user: @user, destination: second_destination
    )

    refute second.success?
    assert_includes second.errors, "confirmation_stale"
    assert_equal saved_version, destination.reload.lock_version
    assert_equal 1, Assistant::AuditEvent.where(event: "draft.confirmed_save", target_id: destination.id.to_s).count
  end

  test "creates an Ansible playbook only after current static policy revalidation" do
    draft = ansible_draft

    missing = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)
    refute missing.success?
    assert_includes missing.errors, "ansible_validation_evidence_missing"

    record_ansible_validation_evidence(draft)
    result = nil
    assert_no_difference [
      -> { ControlCenter::Job.count },
      -> { ControlCenter::Ansible::Run.count },
      -> { ControlCenter::Ansible::ExecutorTask.count }
    ] do
      stub_methods(Assistant::Broker,
        publish: ->(**) { raise "confirmed save must not publish" }) do
        stub_methods(Assistant::ValidationDispatcher,
          call: ->(**) { raise "confirmed save must not dispatch validation" }) do
          result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)
        end
      end
    end

    assert result.success?, result.errors.inspect
    assert_instance_of ControlCenter::Ansible::Playbook, result.record
    assert_equal ANSIBLE_SOURCE, result.record.yaml_content
    assert_equal @user, result.record.created_by
  end

  test "rolls persistence back when the required security audit cannot be recorded" do
    draft = whiterabbit_draft
    result = nil

    assert_no_difference -> { ControlCenter::Template.count } do
      stub_methods(Assistant::Audit,
        record!: ->(**) { raise ActiveRecord::StatementInvalid, "audit unavailable" }) do
        result = Assistant::ConfirmedSave.call(draft: draft, user: @user, destination: nil)
      end
    end

    refute result.success?
    assert_includes result.errors, "persistence_failed"
    assert_nil draft.reload.destination_id
  end

  private

  def whiterabbit_draft(**attributes)
    draft(attributes.reverse_merge(
      artifact_type: "whiterabbit_template",
      name: TEMPLATE_ATTRIBUTES.fetch("name"),
      content: JSON.generate(TEMPLATE_ATTRIBUTES),
      validation_version: Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION
    ))
  end

  def ansible_draft(**attributes)
    draft(attributes.reverse_merge(
      artifact_type: "ansible_playbook",
      name: "Assistant playbook",
      content: ANSIBLE_SOURCE,
      validation_version: Assistant::ValidationDispatcher::VALIDATION_VERSION
    ))
  end

  def draft(attributes)
    Assistant::Draft.create!({
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      validation_details: { "codes" => [], "messages" => [] },
      validation_status: "valid"
    }.merge(attributes))
  end

  def record_ansible_validation_evidence(draft)
    Assistant::Grants::Issuer.call(
      turn: draft.turn,
      resources: [],
      tools: [ "validate_ansible_draft", "get_validation_result" ]
    )
    grant = draft.turn.reload.turn_grant
    request = Assistant::ValidationRequest.create!(
      turn: draft.turn,
      turn_grant: grant,
      status: "pending",
      source: draft.content,
      expires_at: [ grant.expires_at, 4.minutes.from_now ].min
    )
    request.update!(
      status: "valid",
      source: nil,
      result: {
        "normalized" => draft.content,
        "codes" => [],
        "messages" => [],
        "validation_version" => Assistant::ValidationDispatcher::VALIDATION_VERSION
      },
      completed_at: Time.current
    )
  end
end
