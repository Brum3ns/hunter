module Assistant
  class RetentionJob < ApplicationJob
    queue_as :background

    def perform
      Assistant::Retention.purge!(now: Time.current)
    end
  end
end
