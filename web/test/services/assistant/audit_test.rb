require "test_helper"

class Assistant::AuditTest < ActiveSupport::TestCase
  test "audit rejects body-bearing and unknown attributes" do
    error = assert_raises(ArgumentError) do
      Assistant::Audit.record!(event: "tool.called", attributes: { prompt: "secret" })
    end

    assert_includes error.message, "prompt"
  end

  test "audit stores bounded metadata without conversation content" do
    event = Assistant::Audit.record!(
      event: "tool.called",
      attributes: {
        turn_id: assistant_turns(:created).id,
        correlation_id: assistant_turns(:created).correlation_id,
        tool: "get_selected_context",
        status: "accepted",
        byte_count: 123,
        metadata: { operation: "read_context" }
      }
    )

    assert_equal 90.days.from_now.to_date, event.expires_at.to_date
    assert_equal({ "operation" => "read_context" }, event.metadata)
    assert_empty Assistant::AuditEvent.column_names & %w[body prompt response draft_content tool_result]
  end

  test "audit metadata has its own closed key set" do
    assert_raises(ArgumentError) do
      Assistant::Audit.record!(
        event: "tool.called",
        attributes: { metadata: { provider_response: "secret" } }
      )
    end
  end

  test "audit metadata rejects nested and oversized values" do
    assert_raises(ArgumentError) do
      Assistant::Audit.record!(
        event: "tool.called",
        attributes: { metadata: { reason: { provider_response: "secret" } } }
      )
    end
    assert_raises(ArgumentError) do
      Assistant::Audit.record!(
        event: "tool.called",
        attributes: { metadata: { reason: "x" * 256 } }
      )
    end
  end

  test "assistant credentials and bodies are filtered from log parameters" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "turn_grant" => "raw-grant",
      "service_token" => "raw-service-token",
      "authorization" => "Bearer secret",
      "provider_response" => "private",
      "message_body" => "private",
      "draft_content" => "private",
      "validation_details" => "private"
    )

    assert filtered.values.all? { |value| value == "[FILTERED]" }
  end
end
