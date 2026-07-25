module ControlCenter
  module Ansible
    class RunsController < BaseController
      def index
        @run_groups = RunGroup.includes(:runs).order(created_at: :desc, id: :desc).limit(100)
        @ansible_executor_configured = Runner.where("kinds @> ARRAY['ansible']::varchar[]").exists?
      end

      def show
        @run_group = RunGroup.includes(:runs).find_by(id: params[:id])
        return head :not_found unless @run_group

        @run = @run_group.runs.first
        @events = @run ? @run.run_events.oldest_first.limit(200) : []
      end
    end
  end
end
