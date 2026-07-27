require "minitest/autorun"
require_relative "../../../config/environment"
require "active_job/test_helper"

# Standalone: no reachable Postgres here, so `test_helper` (fixtures :all) is
# unusable. TurnJob's own body never has to touch a real database if every AR
# entry point it calls is stubbed away: `Assistant::Turn.find_by`,
# `Assistant::EventIngestor.call`, and `ActiveRecord::Base.transaction` itself
# (which would otherwise try to open a real connection just by being called,
# regardless of what runs inside its block). A plain Struct stands in for the
# turn record.
class Assistant::TurnJobTest < Minitest::Test
  include ActiveJob::TestHelper

  FakeTurn = Struct.new(:id, :status, :provider_profile_id, :correlation_id, :started_at) do
    def update!(attrs)
      attrs.each { |key, value| public_send("#{key}=", value) }
    end
  end

  def setup
    @previous_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    @turn = FakeTurn.new(42, "queued", 7, "11111111-1111-1111-1111-111111111111", nil)
  end

  def teardown
    clear_enqueued_jobs
    clear_performed_jobs
    ActiveJob::Base.queue_adapter = @previous_adapter
  end

  def stub_methods(target, mapping)
    originals = mapping.keys.index_with { |name| target.method(name) }
    mapping.each do |name, impl|
      target.define_singleton_method(name) do |*args, **kwargs, &blk|
        impl.respond_to?(:call) ? impl.call(*args, **kwargs, &blk) : impl
      end
    end
    yield
  ensure
    originals.each { |name, method| target.define_singleton_method(name, method) }
  end

  def without_real_transactions
    stub_methods(ActiveRecord::Base, transaction: ->(&blk) { blk.call }) { yield }
  end

  def find_turn_returning(turn)
    stub_methods(Assistant::Turn, find_by: ->(**) { turn }) { yield }
  end

  def test_no_op_when_turn_is_missing
    calls = 0
    stub_methods(Assistant::GatewayClient, run_turn: ->(*) { calls += 1; [] }) do
      find_turn_returning(nil) do
        without_real_transactions do
          Assistant::TurnJob.new.perform(turn_id: 999, envelope: {})
        end
      end
    end
    assert_equal 0, calls
  end

  def test_no_op_when_turn_is_not_queued
    @turn.status = "running"
    calls = 0
    stub_methods(Assistant::GatewayClient, run_turn: ->(*) { calls += 1; [] }) do
      find_turn_returning(@turn) do
        without_real_transactions do
          Assistant::TurnJob.new.perform(turn_id: @turn.id, envelope: {})
        end
      end
    end
    assert_equal 0, calls
    assert_equal "running", @turn.status
    assert_nil @turn.started_at
  end

  def test_ingests_every_event_in_order_within_one_transaction
    events = [
      { "kind" => "assistant_message", "n" => 1 },
      { "kind" => "draft", "n" => 2 },
      { "kind" => "completed", "n" => 3 }
    ]
    ingested = []
    gateway_calls = 0

    stub_methods(Assistant::GatewayClient, run_turn: ->(*) { gateway_calls += 1; events }) do
      stub_methods(Assistant::EventIngestor, call: ->(event) { ingested << event; :accepted }) do
        find_turn_returning(@turn) do
          without_real_transactions do
            Assistant::TurnJob.new.perform(turn_id: @turn.id, envelope: { "schema_version" => 1 })
          end
        end
      end
    end

    assert_equal 1, gateway_calls
    assert_equal events, ingested
    assert_equal "running", @turn.status
    assert_kind_of Time, @turn.started_at
  end

  def test_records_an_error_event_when_the_gateway_fails_and_calls_it_exactly_once
    ingested = []
    gateway_calls = 0

    stub_methods(Assistant::GatewayClient, run_turn: lambda { |*|
      gateway_calls += 1
      raise Assistant::GatewayClient::Error, "gateway_saturated"
    }) do
      stub_methods(Assistant::EventIngestor, call: ->(event) { ingested << event; :accepted }) do
        find_turn_returning(@turn) do
          without_real_transactions do
            Assistant::TurnJob.new.perform(
              turn_id: @turn.id,
              envelope: { "schema_version" => 1, "correlation_id" => @turn.correlation_id }
            )
          end
        end
      end
    end

    assert_equal 1, gateway_calls
    assert_equal 1, ingested.length
    error_event = ingested.first
    assert_equal "error", error_event["kind"]
    assert_equal "gateway_saturated", error_event.dig("data", "code")
    assert_equal @turn.id, error_event["turn_id"]
    assert_equal @turn.correlation_id, error_event["correlation_id"]
    assert_equal @turn.provider_profile_id, error_event["provider_profile_id"]
    assert_equal 1, error_event["schema_version"]
  end

  def test_gateway_is_called_exactly_once_even_when_ingestion_itself_raises
    gateway_calls = 0
    stub_methods(Assistant::GatewayClient, run_turn: ->(*) { gateway_calls += 1; [ { "kind" => "assistant_message" } ] }) do
      stub_methods(Assistant::EventIngestor, call: ->(_event) { raise "boom" }) do
        find_turn_returning(@turn) do
          without_real_transactions do
            assert_raises(RuntimeError) do
              Assistant::TurnJob.new.perform(turn_id: @turn.id, envelope: {})
            end
          end
        end
      end
    end
    assert_equal 1, gateway_calls
  end

  # This is the single-attempt guarantee itself: run the job through the real
  # ActiveJob enqueue/perform path (not a direct #perform call) so any hidden
  # retry machinery — ActiveJob's own `retry_on`/`rescue_from`, or a
  # Solid Queue default — would show up here. Neither exists in this app
  # (ApplicationJob declares no retry_on, and Solid Queue only re-runs a
  # failed execution on explicit operator action), so a job whose execution
  # raises must be called exactly once and must not leave a second job
  # enqueued behind it.
  def test_a_failing_job_is_attempted_exactly_once_with_no_retry_enqueued
    gateway_calls = 0
    stub_methods(Assistant::GatewayClient, run_turn: ->(*) { gateway_calls += 1; raise "boom" }) do
      stub_methods(Assistant::EventIngestor, call: ->(_event) { :accepted }) do
        find_turn_returning(@turn) do
          without_real_transactions do
            Assistant::TurnJob.perform_later(turn_id: @turn.id, envelope: {})
            assert_equal 1, enqueued_jobs.size

            assert_raises(RuntimeError) { perform_enqueued_jobs }
          end
        end
      end
    end

    assert_equal 1, gateway_calls
    assert_equal 1, performed_jobs.size
    assert_equal 0, enqueued_jobs.size
  end
end
