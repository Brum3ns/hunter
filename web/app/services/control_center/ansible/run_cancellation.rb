module ControlCenter
  module Ansible
    module RunCancellation
      class Conflict < StandardError; end

      ACTIVE_STATUSES = %w[validating running canceling].freeze
      UNCLAIMED_STATUSES = %w[waiting queued].freeze

      module_function

      def cancel_group!(group)
        RunGroup.transaction do
          group.lock!
          raise Conflict, "run group is already terminal" if group.terminal?

          requested_at = group.cancel_requested_at || Time.current
          group.runs.lock.each { |run| request_run_cancellation(run, requested_at) }
          finalize_group_cancellation(group, requested_at)
          group.reload
        end
      end

      def cancel_run!(run)
        RunGroup.transaction do
          group = run.run_group
          group.lock!
          run.lock!
          raise Conflict, "run is already terminal" if run.terminal?

          requested_at = run.cancel_requested_at || Time.current
          request_run_cancellation(run, requested_at)
          finalize_group_cancellation(group, requested_at)
          run.reload
        end
      end

      def request_run_cancellation(run, requested_at)
        attributes = { cancel_requested_at: run.cancel_requested_at || requested_at }
        if UNCLAIMED_STATUSES.include?(run.status)
          attributes.merge!(status: "canceled", completed_at: run.completed_at || requested_at)
        elsif ACTIVE_STATUSES.include?(run.status)
          attributes[:status] = "canceling"
        end
        run.update!(attributes)
      end
      private_class_method :request_run_cancellation

      def finalize_group_cancellation(group, requested_at)
        runs = group.runs.reload
        terminal = runs.all?(&:terminal?)
        attributes = {
          status: terminal ? "canceled" : "canceling",
          cancel_requested_at: group.cancel_requested_at || requested_at,
          completed_at: terminal ? (group.completed_at || requested_at) : group.completed_at
        }
        attributes[:execution_payload] = nil if terminal
        group.update!(attributes)
      end
      private_class_method :finalize_group_cancellation
    end
  end
end
