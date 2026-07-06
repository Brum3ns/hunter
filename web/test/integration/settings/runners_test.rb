require "test_helper"

class Settings::RunnersTest < ActionDispatch::IntegrationTest
  setup { @user = users(:one) }

  test "unauthenticated create redirects to sign in" do
    post settings_runners_path, params: { name: "r", kinds: ["curl"] }
    assert_response :redirect
    assert_equal 0, Runner.count
  end

  test "unauthenticated destroy redirects and keeps the runner" do
    runner, = Runner.generate(name: "r", kinds: %w[curl])
    delete settings_runner_path(runner)
    assert_response :redirect
    assert Runner.exists?(runner.id)
  end

  test "create mints a runner and exposes the raw token once (digest stored)" do
    sign_in_as(@user)
    assert_difference -> { Runner.count }, 1 do
      post settings_runners_path, params: { name: "curl-runner", kinds: ["curl"] }
    end
    assert_redirected_to settings_path
    token = flash[:runner_token]
    assert token.present?
    runner = Runner.find_by!(name: "curl-runner")
    assert_equal %w[curl], runner.kinds
    assert_not_equal token, runner.token_digest
    assert_equal Digest::SHA256.hexdigest(token), runner.token_digest
  end

  test "duplicate name shows an alert and mints nothing" do
    sign_in_as(@user)
    Runner.generate(name: "dup", kinds: %w[curl])
    assert_no_difference -> { Runner.count } do
      post settings_runners_path, params: { name: "dup", kinds: ["curl"] }
    end
    assert_redirected_to settings_path
    assert flash[:alert].present?
  end

  test "no kinds shows an alert and mints nothing" do
    sign_in_as(@user)
    assert_no_difference -> { Runner.count } do
      post settings_runners_path, params: { name: "nokinds" }
    end
    assert flash[:alert].present?
  end

  test "destroy revokes the runner and nullifies its jobs" do
    sign_in_as(@user)
    runner, = Runner.generate(name: "r", kinds: %w[curl])
    job = RunnerJob.create!(kind: "curl", command: "curl https://x", vulnerability_id: "v",
                            requested_by: @user, status: "running", runner: runner, started_at: Time.current)
    delete settings_runner_path(runner)
    assert_redirected_to settings_path
    refute Runner.exists?(runner.id)
    assert RunnerJob.exists?(job.id)
    assert_nil job.reload.runner_id
  end
end
