module Api
  module V1
    module ControlCenter
      module Ansible
        class RunEventsController < Api::V1::BaseController
          api_scope :control_center

          def index
            run = ::ControlCenter::Ansible::Run.find_by(id: params[:run_id])
            return render_not_found unless run

            after_counter = [ params[:after_counter].to_i, 0 ].max
            limit = clamped_limit(default: 100, max: 100)
            events = run.run_events.where(counter: (after_counter + 1)..).oldest_first.limit(limit)
            render json: {
              events: events.map { |event| serialize(event) },
              next_counter: events.last&.counter || after_counter
            }
          end

          private

          def serialize(event)
            {
              id: event.id,
              event_uuid: event.event_uuid,
              parent_uuid: event.parent_uuid,
              counter: event.counter,
              event_type: event.event_type,
              play: event.play,
              task: event.task,
              host: event.host,
              event_time: event.event_time,
              stdout: event.stdout,
              event_data: event.event_data,
              truncated: event.truncated,
              created_at: event.created_at
            }
          end
        end
      end
    end
  end
end
