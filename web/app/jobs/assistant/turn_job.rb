module Assistant
  # Dispatches one turn to the gateway over HTTP and ingests whatever comes
  # back. Enqueued by `Assistant::TurnCreator` only after ITS transaction has
  # committed (see turn_creator.rb) — Solid Queue's `queue` database is
  # separate from the primary one in production, so a worker can pick this
  # job up as soon as it is enqueued, independent of any Ruby-level
  # transaction nesting around the enqueue call.
  #
  # Exactly one gateway call, ever: the gateway is not idempotent with respect
  # to provider spend, so a second attempt would bill a second call and could
  # double-write a draft. `GatewayClient.run_turn` already funnels every
  # transport failure (timeout, dropped connection, oversize/malformed body)
  # into `GatewayClient::Error` — nothing here retries that call, and nothing
  # here asks ActiveJob to retry `perform` itself. Neither Rails 8's
  # `ApplicationJob` nor Solid Queue retries a job automatically unless
  # `retry_on` is declared (verified: `ApplicationJob` declares none, and
  # Solid Queue only re-runs a failed execution on explicit operator/dashboard
  # action) — so a job that never calls `retry_on` and never re-raises out of
  # `perform` back into itself runs the gateway call exactly once, with no
  # extra guard needed.
  class TurnJob < ApplicationJob
    queue_as :default

    def perform(turn_id:, envelope: nil, claude: false, prompt: nil, turn_grant: nil)
      turn = Assistant::Turn.find_by(id: turn_id)
      return unless turn&.status == "queued"

      turn.update!(status: "running", started_at: Time.current)

      events =
        if claude
          # ClaudeCodeClient never raises: every failure is already an error event.
          Assistant::ClaudeCodeClient.run_turn(turn: turn, prompt: prompt, turn_grant: turn_grant)
        else
          begin
            Assistant::GatewayClient.run_turn(envelope)
          rescue Assistant::GatewayClient::Error => error
            [ error_event(turn, error.code) ]
          end
        end

      # A response carrying no events would leave the turn `running` with nothing
      # to observe, so an empty array is itself a failure.
      no_events_code = claude ? "claude_returned_no_events" : "gateway_returned_no_events"
      events = [ error_event(turn, no_events_code) ] if events.empty?

      begin
        ingest_all!(events)
      rescue StandardError => error
        recover!(turn, error)
      end
    end

    private

    # All events from one gateway response are ingested together: a turn
    # response is either fully applied or not applied at all, never applied
    # halfway across separate transactions.
    def ingest_all!(events)
      ActiveRecord::Base.transaction do
        events.each { |event| Assistant::EventIngestor.call(event) }
      end
    end

    # Ingestion can reject a whole response — an unknown event kind, a binding
    # mismatch, a malformed payload. Letting that exception escape `perform` would
    # leave the turn `running` forever with nothing recorded, which is precisely
    # the silent failure this transport change exists to remove. So a rejected
    # response still has to terminate the turn.
    #
    # The first attempt goes back through the normal validated ingestion path so
    # the failure is audited like any other event. Only if that also fails does
    # this write the turn row directly.
    def recover!(turn, cause)
      return if turn.reload.terminal?

      ingest_all!([ error_event(turn, ingestion_failure_code(cause)) ])
    rescue StandardError
      turn.update!(
        status: "failed", completed_at: Time.current, error_code: "event_ingestion_failed"
      )
      Assistant::TurnGrant.where(turn: turn, revoked_at: nil).update_all(
        revoked_at: Time.current, updated_at: Time.current
      )
    end

    # `InvalidEvent#code` is already a stable, non-sensitive reason code. Any other
    # exception is collapsed to a generic code rather than risking its message
    # reaching the turn's error_code.
    def ingestion_failure_code(cause)
      return cause.code if cause.is_a?(Assistant::EventIngestor::InvalidEvent)

      "event_ingestion_failed"
    end

    def error_event(turn, code)
      {
        "schema_version" => 1,
        "event_id" => SecureRandom.uuid,
        "correlation_id" => turn.correlation_id,
        "turn_id" => turn.id,
        "provider_profile_id" => turn.provider_profile_id,
        "kind" => "error",
        "data" => { "code" => code.to_s.first(100) }
      }
    end
  end
end
