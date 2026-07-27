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

    def perform(turn_id:, envelope:)
      turn = Assistant::Turn.find_by(id: turn_id)
      return unless turn&.status == "queued"

      turn.update!(status: "running", started_at: Time.current)

      events =
        begin
          Assistant::GatewayClient.run_turn(envelope)
        rescue Assistant::GatewayClient::Error => error
          [ error_event(turn, error.code) ]
        end

      ingest_all!(events)
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
