require "test_helper"
require "rake"

class SitemapRakeTest < ActiveSupport::TestCase
  test "sitemap:stream task is defined" do
    Hunter::Application.load_tasks unless Rake::Task.task_defined?("sitemap:stream")
    assert Rake::Task.task_defined?("sitemap:stream")
  end
end
