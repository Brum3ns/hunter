require "test_helper"
require "tempfile"

class Assistant::BrokerTest < ActiveSupport::TestCase
  setup do
    @original_environment = %w[
      ASSISTANT_AMQP_HOST
      ASSISTANT_AMQP_PORT
      ASSISTANT_AMQP_PASSWORD_FILE
    ].index_with { |name| ENV[name] }
  end

  teardown do
    @original_environment.each { |name, value| ENV[name] = value }
    Assistant::Broker.reset!
  end

  test "builds the Rails broker connection from a mode-0400 password file" do
    secret_file("queue-password", mode: 0o400) do |path|
      ENV["ASSISTANT_AMQP_HOST"] = "queue.internal"
      ENV["ASSISTANT_AMQP_PORT"] = "5679"
      ENV["ASSISTANT_AMQP_PASSWORD_FILE"] = path

      options = Assistant::Broker.send(:connection_options)

      assert_equal "queue.internal", options.fetch(:host)
      assert_equal 5679, options.fetch(:port)
      assert_equal "/hunter-assistant", options.fetch(:vhost)
      assert_equal "hunter-assistant-rails", options.fetch(:user)
      assert_equal "queue-password", options.fetch(:password)
      refute_includes options.to_json, path
    end
  end

  test "rejects writable password files" do
    secret_file("queue-password", mode: 0o600) do |path|
      ENV["ASSISTANT_AMQP_PASSWORD_FILE"] = path

      assert_raises(ArgumentError) { Assistant::Broker.send(:connection_options) }
    end
  end

  private

  def secret_file(value, mode:)
    Tempfile.create("assistant-amqp") do |file|
      file.write(value)
      file.flush
      File.chmod(mode, file.path)
      yield file.path
    end
  end
end
