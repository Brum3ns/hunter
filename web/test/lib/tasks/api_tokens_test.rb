require "test_helper"
require "rake"

class ApiTokensTaskTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
    Rails.application.load_tasks unless Rake::Task.task_defined?("api_tokens:create")
  end

  def run_task(name)
    Rake::Task[name].reenable
    Rake::Task[name].invoke
  end

  test "create parses SCOPES into the token" do
    ENV["USERNAME"] = @user.username
    ENV["NAME"] = "llm"
    ENV["SCOPES"] = "cves"
    run_task("api_tokens:create")
    assert_equal ["cves"], @user.api_tokens.find_by(name: "llm").scopes
  ensure
    ENV.delete("USERNAME"); ENV.delete("NAME"); ENV.delete("SCOPES")
  end

  test "set_cve_filter stores parsed JSON on the token" do
    token = ApiToken.generate(user: @user, name: "llm", scopes: ["cves"]).first
    ENV["USERNAME"] = @user.username
    ENV["NAME"] = "llm"
    ENV["FILTER"] = '{"ecosystems":["npm"],"min_severity":"high"}'
    run_task("api_tokens:set_cve_filter")
    assert_equal({ "ecosystems" => ["npm"], "min_severity" => "high" }, token.reload.cve_filter)
  ensure
    ENV.delete("USERNAME"); ENV.delete("NAME"); ENV.delete("FILTER")
  end
end
