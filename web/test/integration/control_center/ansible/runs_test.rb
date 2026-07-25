require "test_helper"

class ControlCenter::Ansible::RunsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @group = create_group
  end

  test "run history requires authentication" do
    get control_center_ansible_runs_path
    assert_redirected_to new_session_path

    get control_center_ansible_run_path(@group)
    assert_redirected_to new_session_path
  end

  test "index renders newest-first group history and executor guidance" do
    newer = create_group(playbook_name: "Newest")
    @group.update_column(:created_at, 1.hour.ago)
    sign_in_as(@user)

    get control_center_ansible_runs_path

    assert_response :success
    assert_select "h2", text: "Run history"
    links = css_select("[data-run-history] a[href]").map { |node| node["href"] }
    assert_equal control_center_ansible_run_path(newer), links.first
    assert_select "[data-executor-guidance]", text: /executor/i
    refute_includes response.body, "fleet-secret"
  end

  test "detail mounts polling endpoints and renders immutable selections and events" do
    run = @group.runs.sole
    run.run_events.create!(
      event_uuid: "event-1", counter: 1, event_type: "runner_on_ok",
      play: "Baseline", task: "Install", host: "worker", stdout: "ok"
    )
    sign_in_as(@user)

    get control_center_ansible_run_path(@group)

    assert_response :success
    assert_select "section[data-controller=ansible-runs]" \
                  "[data-ansible-runs-group-url-value=?]" \
                  "[data-ansible-runs-run-url-value=?]" \
                  "[data-ansible-runs-events-url-value=?]" \
                  "[data-ansible-runs-status-value=queued]",
                  api_v1_control_center_ansible_run_group_path(@group),
                  api_v1_control_center_ansible_run_path(run),
                  api_v1_control_center_ansible_run_events_path(run)
    assert_select "[data-ansible-runs-target=status]", text: "queued"
    assert_select "[data-event-counter='1']", text: /Install/
    assert_select "button.hidden[data-ansible-runs-target=retry][data-action='ansible-runs#retry']"
    refute_includes response.body, "fleet-secret"
  end

  test "unknown group returns not found" do
    sign_in_as(@user)

    get control_center_ansible_run_path(0)

    assert_response :not_found
  end

  private

  def create_group(playbook_name: "Baseline")
    ControlCenter::Ansible::RunGroup.create!(
      created_by: @user,
      status: "queued",
      launch_snapshot: {
        "inventory" => { "name" => "Workers" },
        "credential" => { "name" => "Deploy", "fingerprint" => nil }
      },
      execution_payload: { "secrets" => { "ssh_password" => "fleet-secret" } }
    ).tap do |group|
      group.runs.create!(
        position: 0,
        playbook_yaml: "---\n- hosts: workers\n  tasks: []\n",
        inventory_yaml: "---\nall:\n  hosts:\n    worker:\n",
        known_hosts: "worker ssh-ed25519 AAAA",
        playbook_name:,
        inventory_name: "Workers",
        credential_name: "Deploy",
        timeout_seconds: 3600,
        queued_at: Time.current,
        claim_deadline: 5.minutes.from_now
      )
    end
  end
end
