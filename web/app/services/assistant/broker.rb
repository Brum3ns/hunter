require "bunny"

module Assistant
  module Broker
    USERNAME = "hunter-assistant-rails"
    VHOST = "/hunter-assistant"
    MAX_SECRET_BYTES = 16_384

    module_function

    def publish(exchange:, routing_key:, body:, persistent:, expiration:)
      payload = JSON.generate(body)
      channel.confirm_select
      passive_exchange(exchange).publish(
        payload,
        routing_key: routing_key,
        persistent: persistent,
        expiration: expiration.to_s,
        content_type: "application/json",
        type: routing_key,
        message_id: body["event_id"] || body["correlation_id"],
        timestamp: Time.current.to_i
      )
      raise "assistant broker publish was not confirmed" unless channel.wait_for_confirms

      true
    end

    def connection
      @connection ||= Bunny.new(
        **connection_options,
        automatically_recover: true
      ).tap(&:start)
    end

    def channel
      @channel ||= connection.create_channel
    end

    def passive_exchange(name)
      channel.exchange(name, type: "direct", passive: true)
    end
    private_class_method :passive_exchange

    def reset!
      @channel&.close if @channel&.open?
      @connection&.close if @connection&.open?
      @channel = nil
      @connection = nil
    end

    def connection_options
      {
        host: ENV.fetch("ASSISTANT_AMQP_HOST", "rabbitmq"),
        port: Integer(ENV.fetch("ASSISTANT_AMQP_PORT", "5672")),
        vhost: VHOST,
        user: USERNAME,
        password: read_secret(ENV.fetch("ASSISTANT_AMQP_PASSWORD_FILE"))
      }
    rescue ArgumentError => error
      raise if error.message == "assistant broker secret rejected"

      raise ArgumentError, "assistant broker configuration rejected"
    end
    private_class_method :connection_options

    def read_secret(path)
      stat = File.lstat(path)
      permissions = stat.mode & 0o777
      safe_permissions = permissions == 0o400 ||
        (permissions == 0o600 && effectively_read_only?(path))
      valid = stat.file? && !stat.symlink? && safe_permissions &&
        stat.size.positive? && stat.size <= MAX_SECRET_BYTES
      raise ArgumentError, "assistant broker secret rejected" unless valid

      value = File.binread(path, MAX_SECRET_BYTES + 1).strip
      raise ArgumentError, "assistant broker secret rejected" if
        value.empty? || value.match?(/[\x00\s]/)

      value
    rescue SystemCallError
      raise ArgumentError, "assistant broker secret rejected"
    end
    private_class_method :read_secret

    def effectively_read_only?(path)
      # Standalone Compose cannot remap file-backed secret modes. Accept a
      # host-side 0600 source only when its in-container bind mount denies a
      # write open; an ordinary writable 0600 file remains invalid.
      File.open(path, File::WRONLY) {}
      false
    rescue Errno::EROFS, Errno::EACCES
      true
    end
    private_class_method :effectively_read_only?
  end
end
