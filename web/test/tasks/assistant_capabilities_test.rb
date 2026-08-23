require "test_helper"
require "rake"
require "stringio"

class AssistantCapabilitiesTaskTest < Minitest::Test
  def test_verify_task_checks_the_real_catalog_and_api_surface
    Rails.application.load_tasks unless Rake::Task.task_defined?("assistant:capabilities:verify")
    task = Rake::Task["assistant:capabilities:verify"]
    output = capture_stdout do
      task.reenable
      task.invoke
    end

    assert_equal "Verified 186 API operations and 70 MCP tools.\n", output
  end

  private

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end
