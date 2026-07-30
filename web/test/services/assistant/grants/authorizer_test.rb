require "test_helper"

class Assistant::Grants::AuthorizerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "issuer stores only a digest and exact resources" do
    raw = issue_grant
    grant = Assistant::TurnGrant.order(:id).last

    refute_equal raw, grant.token_digest
    assert_equal Digest::SHA256.hexdigest(raw), grant.token_digest
    assert_equal [ { "type" => "target", "id" => "abc" } ], grant.resources
    assert_operator grant.expires_at, :<=, 5.minutes.from_now
  end

  test "reservation verifies tool and exact resource then accounts actual bytes" do
    raw = issue_grant

    reservation = Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw,
      tool: "get_selected_context",
      resource_type: "target",
      resource_id: "abc"
    )
    grant = Assistant::TurnGrant.order(:id).last.reload
    assert_equal 1, grant.call_count
    assert_equal grant.max_result_bytes, grant.reserved_bytes

    assert reservation.complete!(bytes: 123)
    grant.reload
    assert_equal 0, grant.reserved_bytes
    assert_equal 123, grant.returned_bytes
  end

  test "expired grants and unlisted tools or resources fail closed" do
    raw = issue_grant
    grant = Assistant::TurnGrant.order(:id).last
    grant.update_column(:expires_at, 1.second.ago)

    error = assert_raises(Assistant::Grants::AuthorizationError) do
      Assistant::Grants::Authorizer.reserve!(
        raw_grant: raw,
        tool: "get_selected_context",
        resource_type: "target",
        resource_id: "abc"
      )
    end
    assert_equal "grant_expired", error.code

    raw = issue_grant
    assert_authorization_error("tool_not_allowed") do
      Assistant::Grants::Authorizer.reserve!(raw_grant: raw, tool: "unknown_tool")
    end
    assert_authorization_error("resource_not_allowed") do
      Assistant::Grants::Authorizer.reserve!(
        raw_grant: raw,
        tool: "get_selected_context",
        resource_type: "target",
        resource_id: "other"
      )
    end
  end

  test "oversized completion is discarded and revokes the grant" do
    raw = issue_grant
    reservation = Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw,
      tool: "get_selected_context",
      resource_type: "target",
      resource_id: "abc"
    )
    grant = Assistant::TurnGrant.order(:id).last

    refute reservation.complete!(bytes: grant.max_result_bytes + 1)
    grant.reload
    assert_not_nil grant.revoked_at
    assert_equal 0, grant.returned_bytes
    assert_equal 0, grant.reserved_bytes
    assert Assistant::AuditEvent.exists?(event: "grant.result_rejected", status: "rejected")
  end

  test "complete_write! accounts bytes like complete! on the happy path" do
    raw = issue_grant
    reservation = Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw,
      tool: "get_selected_context",
      resource_type: "target",
      resource_id: "abc"
    )
    grant = Assistant::TurnGrant.order(:id).last.reload

    assert reservation.complete_write!(bytes: 123)
    grant.reload
    assert_equal 0, grant.reserved_bytes
    assert_equal 123, grant.returned_bytes
    assert_nil grant.revoked_at
  end

  test "complete_write! never signals a rejection even when the byte limit is overrun" do
    raw = issue_grant
    reservation = Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw,
      tool: "get_selected_context",
      resource_type: "target",
      resource_id: "abc"
    )
    grant = Assistant::TurnGrant.order(:id).last

    # An already-committed write must never be reported as rejected: the
    # accounting still records the overrun (and revokes further use of the
    # grant), but the caller always gets a truthy result back.
    assert reservation.complete_write!(bytes: grant.max_result_bytes + 1)
    grant.reload
    assert_not_nil grant.revoked_at
    assert_equal grant.max_result_bytes + 1, grant.returned_bytes
    assert_equal 0, grant.reserved_bytes
    assert Assistant::AuditEvent.exists?(event: "grant.result_rejected", status: "rejected")
  end

  test "issued scope and identity bindings cannot be broadened" do
    issue_grant
    grant = Assistant::TurnGrant.order(:id).last

    grant.tools = grant.tools + [ "get_authoring_policy" ]
    grant.resources = grant.resources + [ { "type" => "target", "id" => "other" } ]

    refute grant.valid?
    assert_includes grant.errors[:tools], "cannot be changed"
    assert_includes grant.errors[:resources], "cannot be changed"
  end

  test "a completion after grant expiry is discarded" do
    raw = issue_grant
    reservation = Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw,
      tool: "get_selected_context",
      resource_type: "target",
      resource_id: "abc"
    )
    grant = Assistant::TurnGrant.order(:id).last
    grant.update_column(:expires_at, 1.second.ago)

    refute reservation.complete!(bytes: 123)
    assert_equal 0, grant.reload.returned_bytes
    assert_equal 0, grant.reserved_bytes
    assert_equal "expired", Assistant::AuditEvent.order(:id).last.metadata.fetch("reason")
  end

  test "concurrent reservations cannot overrun the cumulative budget" do
    raw = issue_grant
    grant = Assistant::TurnGrant.order(:id).last
    grant.update_columns(max_calls: 2, max_total_bytes: grant.max_result_bytes)
    outcomes = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Assistant::Grants::Authorizer.reserve!(
            raw_grant: raw,
            tool: "get_selected_context",
            resource_type: "target",
            resource_id: "abc"
          )
          outcomes << "reserved"
        rescue Assistant::Grants::AuthorizationError => error
          outcomes << error.code
        end
      end
    end
    threads.each(&:join)

    assert_equal [ "grant_budget_exhausted", "reserved" ], 2.times.map { outcomes.pop }.sort
    assert_equal grant.max_result_bytes, grant.reload.reserved_bytes
    assert_equal 1, grant.call_count
  end

  test "a scoped read tool is refused unless its scope is granted" do
    raw = issue_read_grant
    grant = Assistant::TurnGrant.order(:id).last
    grant.update_column(:read_scopes, [])

    assert_authorization_error("scope_not_allowed") do
      Assistant::Grants::Authorizer.reserve!(raw_grant: raw, tool: "list_targets", scope: "targets")
    end
  end

  test "a scoped read tool is allowed when its scope is granted" do
    raw = issue_read_grant

    assert Assistant::Grants::Authorizer.reserve!(raw_grant: raw, tool: "list_targets", scope: "targets")
    assert_equal 1, Assistant::TurnGrant.order(:id).last.reload.call_count
  end

  test "a scoped write tool is refused unless its scope is granted" do
    raw = issue_write_grant
    grant = Assistant::TurnGrant.order(:id).last
    grant.update_column(:write_scopes, [])

    assert_authorization_error("scope_not_allowed") do
      Assistant::Grants::Authorizer.reserve!(
        raw_grant: raw, tool: "create_ansible_playbook", scope: "control_center_ansible_write"
      )
    end
  end

  test "a scoped write tool is allowed when its scope is granted" do
    raw = issue_write_grant

    assert Assistant::Grants::Authorizer.reserve!(
      raw_grant: raw, tool: "create_ansible_playbook", scope: "control_center_ansible_write"
    )
    assert_equal 1, Assistant::TurnGrant.order(:id).last.reload.call_count
  end

  private

  def issue_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [ { type: "target", id: "abc" } ],
      tools: [ "get_selected_context" ]
    )
  end

  def issue_read_grant
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "list_targets" ]
    )
  end

  def issue_write_grant
    Assistant::Setting.instance.update!(control_center_write_enabled: true)
    Assistant::Grants::Issuer.call(
      turn: assistant_turns(:created),
      resources: [],
      tools: [ "create_ansible_playbook" ]
    )
  end

  def assert_authorization_error(code, &block)
    error = assert_raises(Assistant::Grants::AuthorizationError, &block)
    assert_equal code, error.code
  end
end
