module Api
  module V1
    module ControlCenter
      # RabbitMQ + Mongo reachability, checked through the binary's -check-* flags.
      class HealthController < BaseController
        def show
          render json: ::ControlCenter::Standalone.health
        end
      end
    end
  end
end
