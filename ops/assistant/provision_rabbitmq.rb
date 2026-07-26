#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "logger"
require "net/http"
require "uri"
require "bunny"

class AssistantRabbitProvisioner
  class ProvisioningCredentialUnavailable < StandardError; end

  VHOST = "/hunter-assistant"
  EXCHANGES = %w[assistant.turns assistant.events assistant.validations assistant.validation_events].freeze
  QUEUES = {
    "assistant.gateway.turns" => "assistant.turns",
    "assistant.rails.events" => "assistant.events",
    "assistant.validator.requests" => "assistant.validations",
    "assistant.rails.validation_events" => "assistant.validation_events"
  }.freeze
  USERS = {
    "hunter-assistant-rails" => {
      password_file: "ASSISTANT_RAILS_AMQP_PASSWORD_FILE",
      write: "^(assistant\\.turns|assistant\\.validations)$",
      read: "^(assistant\\.rails\\.events|assistant\\.rails\\.validation_events)$"
    },
    "hunter-assistant-gateway" => {
      password_file: "ASSISTANT_GATEWAY_AMQP_PASSWORD_FILE",
      write: "^assistant\\.events$",
      read: "^assistant\\.gateway\\.turns$"
    },
    "hunter-assistant-validator" => {
      password_file: "ASSISTANT_VALIDATOR_AMQP_PASSWORD_FILE",
      write: "^assistant\\.validation_events$",
      read: "^assistant\\.validator\\.requests$"
    }
  }.freeze

  def self.run
    path = ENV.fetch("RABBITMQ_PROVISION_PASSWORD_FILE")
    stat = File.lstat(path)
    return if stat.file? && !stat.symlink? && stat.size.zero?

    new.call
  end

  def initialize
    @base = URI(ENV.fetch("RABBITMQ_MANAGEMENT_URL", "http://rabbitmq:15672"))
    @admin_user = ENV.fetch("RABBITMQ_PROVISION_USERNAME", "assistant-provisioner")
    @admin_password = read_secret("RABBITMQ_PROVISION_PASSWORD_FILE")
  end

  def call
    delete_if_present("/api/vhosts/#{escape(VHOST)}")
    put("/api/vhosts/#{escape(VHOST)}", description: "Hunter isolated non-durable assistant vhost")
    EXCHANGES.each { |name| put("/api/exchanges/#{escape(VHOST)}/#{escape(name)}", exchange_body) }
    QUEUES.each_key { |name| put("/api/queues/#{escape(VHOST)}/#{escape(name)}", queue_body) }
    QUEUES.each do |queue, exchange|
      post("/api/bindings/#{escape(VHOST)}/e/#{escape(exchange)}/q/#{escape(queue)}", routing_key: queue, arguments: {})
    end
    USERS.each { |name, permissions| provision_user(name, permissions) }
    disable_tracing
    delete_provisioner
  rescue ProvisioningCredentialUnavailable
    return :already_provisioned if topology_ready?

    raise
  end

  private

  def provision_user(name, permissions)
    put("/api/users/#{escape(name)}", password: read_secret(permissions.fetch(:password_file)), tags: "")
    put("/api/permissions/#{escape(VHOST)}/#{escape(name)}", {
      configure: "^$", write: permissions.fetch(:write), read: permissions.fetch(:read)
    })
  end

  def exchange_body
    { type: "direct", durable: false, auto_delete: false, internal: false, arguments: {} }
  end

  def queue_body
    { durable: false, auto_delete: false, arguments: { "x-expires" => 3_600_000 } }
  end

  def disable_tracing
    traces = request(Net::HTTP::Get, "/api/traces/#{escape(VHOST)}")
    Array(traces).each do |trace|
      request(Net::HTTP::Delete, "/api/traces/#{escape(VHOST)}/#{escape(trace.fetch('name'))}")
    end
  end

  def put(path, body)
    request(Net::HTTP::Put, path, body)
  end

  def post(path, body)
    request(Net::HTTP::Post, path, body)
  end

  def delete(path)
    request(Net::HTTP::Delete, path)
  end

  def delete_if_present(path)
    request(Net::HTTP::Delete, path, nil, allow_not_found: true)
  end

  def delete_provisioner
    delete("/api/users/#{escape(@admin_user)}")
  end

  def request(request_class, path, body = nil, allow_not_found: false)
    uri = @base + path
    request = request_class.new(uri)
    request.basic_auth(@admin_user, @admin_password)
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end
    if response.is_a?(Net::HTTPUnauthorized) || response.is_a?(Net::HTTPForbidden)
      raise ProvisioningCredentialUnavailable, "RabbitMQ provisioning credential unavailable"
    end
    return if allow_not_found && response.is_a?(Net::HTTPNotFound)
    unless response.is_a?(Net::HTTPSuccess)
      raise "RabbitMQ provisioning failed: #{request.method} #{path} status=#{response.code}"
    end

    response.body.to_s.empty? ? nil : JSON.parse(response.body)
  end

  def topology_ready?
    USERS.all? do |name, permissions|
      connection = Bunny.new(
        host: ENV.fetch("RABBITMQ_AMQP_HOST", "rabbitmq"),
        port: Integer(ENV.fetch("RABBITMQ_AMQP_PORT", "5672"), 10),
        vhost: VHOST,
        user: name,
        password: read_secret(permissions.fetch(:password_file)),
        connection_timeout: 2,
        automatically_recover: false,
        logger: Logger.new(File::NULL)
      )
      connection.start
      true
    rescue StandardError
      false
    ensure
      begin
        connection&.close
      rescue StandardError
        nil
      end
    end
  end

  def read_secret(env_name)
    path = ENV.fetch(env_name)
    stat = File.lstat(path)
    permissions = stat.mode & 0o777
    safe_permissions = permissions == 0o400 ||
      (permissions == 0o600 && effectively_read_only?(path))
    unless stat.file? && !stat.symlink? && safe_permissions
      raise "#{env_name} must reference a read-only regular non-symlink file"
    end

    value = File.binread(path, 16_385).strip
    if value.empty? || value.bytesize > 16_384 || value.match?(/[\x00\s]/)
      raise "#{env_name} is empty, malformed, or too large"
    end

    value
  end

  def effectively_read_only?(path)
    File.open(path, File::WRONLY) {}
    false
  rescue Errno::EROFS, Errno::EACCES
    true
  end

  def escape(value)
    URI.encode_www_form_component(value)
  end
end

AssistantRabbitProvisioner.run if $PROGRAM_NAME == __FILE__
