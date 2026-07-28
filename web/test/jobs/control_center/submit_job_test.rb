require "test_helper"

class ControlCenter::SubmitJobTest < ActiveSupport::TestCase
  Result = Struct.new(:exit_status, :stdout, :stderr, :error, keyword_init: true)

  def queued_job(**over)
    ControlCenter::Job.create!({ template_name: "httpx", status: "queued", queue_name: "test",
      target_count: 0, selections: [{ "source" => "targets", "q" => "x" }], target_chunk: 0 }.merge(over))
  end

  setup do
    ControlCenter::Template.create!(name: "httpx", commands: [{ "command" => "httpx", "args" => [] }])
  end

  test "streams targets to a file, records the count, and finalizes succeeded" do
    job = queued_job
    captured = {}
    stub_methods(ControlCenter::TargetSelection, stream: ->(sels, manual, &blk) { %w[a.com b.com].each(&blk); 2 }) do
      stub_methods(ControlCenter::Standalone,
        submit: ->(template:, target_file:, queue_name:, target_chunk:, delay:) {
          captured = { file: File.read(target_file), chunk: target_chunk }
          Result.new(exit_status: 0, stdout: "done", stderr: "", error: nil)
        }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    job.reload
    assert_equal "succeeded", job.status
    assert_equal 2, job.target_count
    assert_equal "a.com\nb.com\n", captured[:file]
    assert_equal ControlCenter::SubmitJob::DEFAULT_CHUNK, captured[:chunk] # blank chunk -> default
  end

  test "a non-zero exit finalizes failed with captured stderr" do
    job = queued_job
    stub_methods(ControlCenter::TargetSelection, stream: ->(_s, _m, &blk) { blk.call("a.com"); 1 }) do
      stub_methods(ControlCenter::Standalone,
        submit: ->(**) { Result.new(exit_status: 3, stdout: "", stderr: "nope", error: nil) }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    assert_equal "failed", job.reload.status
    assert_equal "nope", job.stderr
  end

  test "a submitted chunk value is preserved" do
    job = queued_job(target_chunk: 500)
    got = nil
    stub_methods(ControlCenter::TargetSelection, stream: ->(_s, _m, &blk) { blk.call("a"); 1 }) do
      stub_methods(ControlCenter::Standalone, submit: ->(target_chunk:, **) { got = target_chunk; Result.new(exit_status: 0, stdout: "", stderr: "", error: nil) }) do
        ControlCenter::SubmitJob.perform_now(job.id)
      end
    end
    assert_equal 500, got
  end

  test "a missing template fails the job without raising" do
    job = queued_job(template_name: "gone")
    ControlCenter::SubmitJob.perform_now(job.id)
    assert_equal "failed", job.reload.status
  end

  test "an incomplete target resolution marks the job failed and re-raises" do
    job = queued_job
    stub_methods(ControlCenter::TargetSelection,
      stream: ->(_s, _m, &blk) { raise ControlCenter::TargetSelection::ResolutionIncomplete, "targets source read was incomplete (Mongo error)" }) do
      error = assert_raises(ControlCenter::TargetSelection::ResolutionIncomplete) { ControlCenter::SubmitJob.perform_now(job.id) }
      assert_match(/incomplete/i, error.message)
    end
    job.reload
    assert_equal "failed", job.status
    assert_match(/incomplete/i, job.stderr)
  end

  test "a generic unexpected exception marks the job failed and re-raises" do
    job = queued_job
    stub_methods(ControlCenter::TargetSelection, stream: ->(_s, _m, &blk) { blk.call("a.com"); 1 }) do
      stub_methods(ControlCenter::Standalone, submit: ->(**) { raise "boom" }) do
        error = assert_raises(RuntimeError) { ControlCenter::SubmitJob.perform_now(job.id) }
        assert_equal "boom", error.message
      end
    end
    job.reload
    assert_equal "failed", job.status
    assert_equal "boom", job.stderr
  end
end
