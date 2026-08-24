require "test_helper"

class Api::V1::Assistant::ConfirmedSavesTest < ActionDispatch::IntegrationTest
  TEMPLATE_ATTRIBUTES = {
    "name" => "Assistant probe",
    "kind" => "cmdscript",
    "description" => "Review before saving",
    "commands" => [
      { "command" => "httpx", "args" => [ "-silent", "-l", "__TARGET_FILE__" ], "operator" => "" }
    ]
  }.freeze

  setup do
    @admin = users(:one)
    @original_admin_username = ENV["ADMIN_USERNAME"]
    ENV["ADMIN_USERNAME"] = @admin.username
    sign_in_as(@admin)
  end

  teardown do
    ENV["ADMIN_USERNAME"] = @original_admin_username
  end

  test "a separate confirmed request saves the complete reviewed draft" do
    draft = whiterabbit_draft

    post confirmed_save_path(draft), params: confirmation_for(draft), as: :json

    assert_response :created
    artifact = response.parsed_body.fetch("artifact")
    assert_equal %w[content_hash id lock_version type], artifact.keys.sort
    assert_equal "whiterabbit_template", artifact.fetch("type")
    assert_equal draft.name, ControlCenter::Template.find(artifact.fetch("id")).name
    assert_match(/\A\h{64}\z/, artifact.fetch("content_hash"))
  end

  test "confirmation is CSRF protected and rejects bearer authentication" do
    draft = whiterabbit_draft
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    post confirmed_save_path(draft), params: confirmation_for(draft), as: :json
    assert_response :forbidden
    assert_equal "invalid_csrf_token", response.parsed_body.fetch("error")

    ActionController::Base.allow_forgery_protection = false
    delete session_path
    _token, raw = ApiToken.generate(user: @admin, name: "all", scopes: [ "*" ])
    post confirmed_save_path(draft), params: confirmation_for(draft),
      headers: { "Authorization" => "Bearer #{raw}" }, as: :json
    assert_response :unauthorized
    assert_equal "session_required", response.parsed_body.fetch("error")
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  test "confirmation is owner scoped" do
    draft = whiterabbit_draft(
      conversation: assistant_conversations(:other_user),
      turn: assistant_turns(:other_user)
    )

    post confirmed_save_path(draft), params: confirmation_for(draft), as: :json

    assert_response :not_found
    assert_equal "not_found", response.parsed_body.fetch("error")
  end

  test "confirmation binds the displayed content validation and destination" do
    draft = whiterabbit_draft

    post confirmed_save_path(draft), params: {
      confirmation: confirmation_for(draft).fetch(:confirmation).merge(
        name: "Different displayed name",
        content_digest: Digest::SHA256.hexdigest("different content"),
        diff_digest: Digest::SHA256.hexdigest("different diff")
      )
    }, as: :json

    assert_response :unprocessable_entity
    assert_equal "confirmation_mismatch", response.parsed_body.fetch("error")
    assert_includes response.parsed_body.fetch("errors"), "name_mismatch"
    assert_includes response.parsed_body.fetch("errors"), "content_digest_mismatch"
    assert_includes response.parsed_body.fetch("errors"), "diff_digest_mismatch"
    assert_equal 0, ControlCenter::Template.count
  end

  test "a stale destination returns conflict and preserves the concurrent edit" do
    destination = ControlCenter::Template.create!(TEMPLATE_ATTRIBUTES.merge("description" => "Original"))
    draft = whiterabbit_draft(
      destination_type: "whiterabbit_template",
      destination_id: destination.id.to_s,
      destination_lock_version: destination.lock_version.to_s
    )
    destination.update!(description: "Concurrent edit")

    post confirmed_save_path(draft), params: confirmation_for(draft), as: :json

    assert_response :conflict
    assert_equal "destination_stale", response.parsed_body.fetch("error")
    assert_equal "Concurrent edit", destination.reload.description
  end

  test "an unchanged reviewed destination is updated through shared persistence" do
    destination = ControlCenter::Template.create!(TEMPLATE_ATTRIBUTES.merge("description" => "Original"))
    reviewed_version = destination.lock_version
    draft = whiterabbit_draft(
      destination_type: "whiterabbit_template",
      destination_id: destination.id.to_s,
      destination_lock_version: reviewed_version.to_s
    )

    post confirmed_save_path(draft), params: confirmation_for(draft), as: :json

    assert_response :success
    artifact = response.parsed_body.fetch("artifact")
    assert_equal destination.id, artifact.fetch("id")
    assert_operator artifact.fetch("lock_version"), :>, reviewed_version
    assert_equal TEMPLATE_ATTRIBUTES.fetch("description"), destination.reload.description
    assert_equal artifact.fetch("lock_version").to_s, draft.reload.destination_lock_version
  end

  test "draft review returns a complete destination diff and binds its digest" do
    destination = ControlCenter::Template.create!(TEMPLATE_ATTRIBUTES.merge("description" => "Original"))
    draft = whiterabbit_draft(
      destination_type: "whiterabbit_template",
      destination_id: destination.id.to_s,
      destination_lock_version: destination.lock_version.to_s
    )

    get "/api/v1/assistant/drafts/#{draft.id}"

    assert_response :success
    body = response.parsed_body
    assert_includes body.fetch("diff"), "Original"
    assert_includes body.fetch("diff"), TEMPLATE_ATTRIBUTES.fetch("description")
    assert_equal Digest::SHA256.hexdigest(body.fetch("diff")), body.fetch("diff_digest")
    assert_equal({
      "type" => "whiterabbit_template",
      "id" => destination.id.to_s,
      "lock_version" => destination.lock_version.to_s
    }, body.fetch("destination"))
  end

  private

  def whiterabbit_draft(**attributes)
    Assistant::Draft.create!({
      conversation: assistant_conversations(:one),
      turn: assistant_turns(:created),
      artifact_type: "whiterabbit_template",
      name: TEMPLATE_ATTRIBUTES.fetch("name"),
      content: JSON.generate(TEMPLATE_ATTRIBUTES),
      validation_details: { "codes" => [], "messages" => [] },
      validation_status: "valid",
      validation_version: Assistant::DraftValidation::Whiterabbit::VALIDATION_VERSION
    }.merge(attributes))
  end

  def confirmation_for(draft)
    destination = if draft.destination_type.present?
      {
        type: draft.destination_type,
        id: draft.destination_id,
        lock_version: draft.destination_lock_version
      }
    end
    {
      confirmation: {
        name: draft.name,
        content_digest: draft.content_digest,
        validation_version: draft.validation_version,
        diff_digest: reviewed_diff_digest(draft),
        destination: destination
      }
    }
  end

  def reviewed_diff_digest(draft)
    return if draft.destination_type.blank?

    destination = ControlCenter::Template.find_by(id: draft.destination_id)
    return unless destination

    current = ControlCenter::TemplateRenderer.to_yaml(destination)
    parsed = Assistant::DraftEnvelope.whiterabbit(JSON.parse(draft.content))
    proposed = ControlCenter::TemplateRenderer.to_yaml(ControlCenter::Template.new(parsed.normalized))
    diff = "--- current\n+++ proposed\n-#{current}\n+#{proposed}"
    Digest::SHA256.hexdigest(diff)
  end

  def confirmed_save_path(draft)
    "/api/v1/assistant/drafts/#{draft.id}/confirmed_save"
  end
end
