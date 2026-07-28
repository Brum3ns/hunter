module Api
  module V1
    module AnsibleExecutor
      class RunEventsController < BaseController
        def create
          run = ::ControlCenter::Ansible::Run.find_by(id: params[:id])
          return render_not_found unless run

          events = Array(params[:events]).map do |event|
            event.respond_to?(:to_unsafe_h) ? event.to_unsafe_h : event.to_h
          end
          records = ::ControlCenter::Ansible::RunEventIngestor.call(
            run:,
            runner: Current.runner,
            lease: lease_token,
            events:
          )
          render json: { accepted: records.length, last_counter: records.last&.counter }
        end
      end
    end
  end
end
