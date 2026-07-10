require "minitest/autorun"
require_relative "../agent"

class RunnerAgentTest < Minitest::Test
  # A RunnerAgent with the network and curl seams overridden so we can observe
  # how many jobs run at the same time. It hands out a fixed number of jobs, then
  # reports empty, and records the peak number of simultaneously-executing jobs.
  class FakeAgent < RunnerAgent
    attr_reader :peak

    def initialize(job_count:, concurrency:)
      super(api: "http://x", token: "t", poll: 0.001,
            max_time: 1, max_output: 1, concurrency: concurrency)
      @remaining = job_count
      @submitted = 0
      @active = 0
      @peak = 0
      @lock = Mutex.new
    end

    def claim
      @lock.synchronize do
        return nil if @remaining <= 0

        @remaining -= 1
        { "id" => @remaining, "command" => "curl https://example.test" }
      end
    end

    def execute_job(_command)
      @lock.synchronize do
        @active += 1
        @peak = [@peak, @active].max
      end
      sleep 0.05
      @lock.synchronize { @active -= 1 }
      :result
    end

    def submit(_id, _result)
      @lock.synchronize { @submitted += 1 }
      Struct.new(:code).new("200")
    end

    def submitted
      @lock.synchronize { @submitted }
    end
  end

  def test_runs_jobs_concurrently_up_to_the_limit
    agent = FakeAgent.new(job_count: 12, concurrency: 4)
    agent.run(stop: -> { agent.submitted >= 12 })

    assert_equal 12, agent.submitted
    assert_equal 4, agent.peak, "expected all 4 workers busy at once, not serialized"
  end

  def test_concurrency_of_one_stays_serial
    agent = FakeAgent.new(job_count: 5, concurrency: 1)
    agent.run(stop: -> { agent.submitted >= 5 })

    assert_equal 5, agent.submitted
    assert_equal 1, agent.peak
  end
end
