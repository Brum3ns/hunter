module Assistant
  module EventConsumer
    QUEUES = %w[assistant.rails.events assistant.rails.validation_events].freeze
    MAX_EVENT_BYTES = 300_000

    module_function

    def run
      sleep 5 until Assistant::Config.enabled?

      channel = Assistant::Broker.connection.create_channel
      channel.prefetch(8)
      QUEUES.each do |name|
        channel.queue(name, passive: true).subscribe(manual_ack: true, block: false) do |delivery, properties, body|
          consume(channel, delivery, properties, body, queue: name)
        end
      end
      sleep 1 while channel.open?
    ensure
      channel&.close if channel&.open?
    end

    def consume(channel, delivery, properties, body, queue: "assistant.rails.events")
      unless properties.content_type == "application/json" && body.bytesize <= MAX_EVENT_BYTES
        return reject(channel, delivery, "invalid_envelope")
      end

      payload = JSON.parse(body)
      if queue == "assistant.rails.validation_events"
        Assistant::ValidationDispatcher.ingest!(payload)
      else
        Assistant::EventIngestor.call(payload)
      end
      channel.ack(delivery.delivery_tag, false)
    rescue JSON::ParserError, Assistant::EventIngestor::InvalidEvent,
      Assistant::ValidationDispatcher::InvalidEvent => error
      code = error.respond_to?(:code) ? error.code : "invalid_json"
      reject(channel, delivery, code)
    end

    def reject(channel, delivery, code)
      Rails.logger.warn("assistant event rejected code=#{code}")
      channel.reject(delivery.delivery_tag, false)
    end
    private_class_method :reject
  end
end
