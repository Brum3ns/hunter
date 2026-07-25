module Api
  module V1
    module AnsibleExecutor
      class TasksController < BaseController
        def claim
          claim = ::ControlCenter::Ansible::ExecutorTaskClaim.call(runner: Current.runner)
          return head :no_content unless claim

          render json: {
            id: claim.task.id,
            kind: claim.task.kind,
            lease: claim.lease,
            lease_expires_at: claim.lease_expires_at,
            payload: claim.payload
          }
        end

        def heartbeat
          task = find_task
          return render_not_found unless task

          ::ControlCenter::Ansible::ExecutorTask.transaction do
            task.lock!
            ::ControlCenter::Ansible::LeaseVerifier.verify!(
              task, runner: Current.runner, lease: lease_token, statuses: [ "running" ]
            )
            now = Time.current
            task.update!(heartbeat_at: now, lease_expires_at: now + lease_seconds)
          end
          render json: task_state(task)
        end

        def result
          task = find_task
          return render_not_found unless task

          output = params[:result]
          output = output.to_unsafe_h if output.respond_to?(:to_unsafe_h)
          task = ::ControlCenter::Ansible::ExecutorTaskResult.call(
            task:,
            runner: Current.runner,
            lease: lease_token,
            result: params.to_unsafe_h.slice("status", "error_code", "error_detail").merge("result" => output)
          )
          render json: task_state(task)
        end

        private

        def find_task
          ::ControlCenter::Ansible::ExecutorTask.find_by(id: params[:id])
        end

        def task_state(task)
          {
            id: task.id,
            kind: task.kind,
            status: task.status,
            heartbeat_at: task.heartbeat_at,
            lease_expires_at: task.lease_expires_at,
            completed_at: task.completed_at
          }
        end
      end
    end
  end
end
