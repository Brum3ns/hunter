require "minitest/autorun"

require_relative "../../../../ops/assistant/provision_rabbitmq"

class AssistantRabbitProvisionerTest < Minitest::Test
  def test_successful_provisioning_deletes_the_temporary_administrator_last
    provisioner, requests = provisioner_with_fake_http

    provisioner.call

    assert_equal Net::HTTP::Delete, requests.last.fetch(:request_class)
    assert_equal "/api/users/assistant-provisioner", requests.last.fetch(:path)
    created_users = requests
      .select { |request| request.fetch(:request_class) == Net::HTTP::Put }
      .map { |request| request.fetch(:path) }
      .grep(%r{\A/api/users/})
    assert_equal AssistantRabbitProvisioner::USERS.keys.sort,
      created_users.map { |path| path.delete_prefix("/api/users/") }.sort
  end

  def test_failed_provisioning_leaves_the_temporary_administrator_for_a_bounded_retry
    provisioner, requests = provisioner_with_fake_http(fail_first: true)

    error = assert_raises(RuntimeError) { provisioner.call }

    assert_equal "simulated topology failure", error.message
    refute(requests.any? do |request|
      request.fetch(:request_class) == Net::HTTP::Delete &&
        request.fetch(:path) == "/api/users/assistant-provisioner"
    end)
  end

  def test_missing_temporary_administrator_is_success_when_all_service_accounts_connect
    provisioner, = provisioner_with_fake_http
    provisioner.define_singleton_method(:request) do |*_args|
      raise AssistantRabbitProvisioner::ProvisioningCredentialUnavailable,
        "RabbitMQ provisioning credential unavailable"
    end
    provisioner.define_singleton_method(:topology_ready?) { true }

    assert_equal :already_provisioned, provisioner.call
  end

  private

  def provisioner_with_fake_http(fail_first: false)
    requests = []
    provisioner = AssistantRabbitProvisioner.allocate
    provisioner.instance_variable_set(:@admin_user, "assistant-provisioner")
    provisioner.define_singleton_method(:read_secret) { |_env_name| "test-secret" }
    provisioner.define_singleton_method(:request) do |request_class, path, body = nil, **_options|
      requests << { request_class: request_class, path: path, body: body }
      if fail_first && requests.length == 1
        raise "simulated topology failure"
      end

      request_class == Net::HTTP::Get ? [] : nil
    end

    [ provisioner, requests ]
  end
end
