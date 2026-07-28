require "test_helper"

class Assistant::TurnGrantTest < ActiveSupport::TestCase
  test "an issued grant carries the default read scopes" do
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    assert_equal Assistant::TurnGrant::READ_SCOPES, grant.read_scopes
  end

  test "read_scopes cannot be changed after issue" do
    issue!
    grant = Assistant::TurnGrant.order(:id).last
    grant.read_scopes = grant.read_scopes + [ "targets" ]
    refute grant.valid?
    assert_includes grant.errors[:read_scopes], "cannot be changed"
  end

  test "unknown read scope slugs are rejected on create" do
    issue!
    template = Assistant::TurnGrant.order(:id).last
    clone = Assistant::TurnGrant.new(
      template.attributes.except("id", "created_at", "updated_at", "token_digest")
    )
    clone.token_digest = Assistant::TurnGrant.digest("another-secret")
    clone.read_scopes = [ "bogus" ]
    refute clone.valid?
    assert(clone.errors[:read_scopes].any? { |message| message.include?("unknown") })
  end

  private

  def issue!
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [ "get_selected_context" ]
    )
  end
end
