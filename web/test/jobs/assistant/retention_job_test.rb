require "test_helper"

class Assistant::RetentionJobTest < ActiveJob::TestCase
  test "delegates to metadata-only batched retention" do
    called_at = nil

    stub_methods(Assistant::Retention, purge!: ->(now:) { called_at = now; {} }) do
      Assistant::RetentionJob.perform_now
    end

    assert_in_delta Time.current, called_at, 2.seconds
  end
end
