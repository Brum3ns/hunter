module Settings
  # Saves the current user's Scope recurring-fetch schedule (Settings → Fetch
  # schedule). Idempotent: builds the row on first save, updates it thereafter.
  class SchedulesController < ApplicationController
    def update
      schedule = Current.user.scope_schedule || Current.user.build_scope_schedule
      schedule.assign_attributes(schedule_params)
      schedule.recompute_next_run_at!

      if schedule.save
        redirect_to settings_path(anchor: "schedule"), notice: "Fetch schedule saved."
      else
        redirect_to settings_path(anchor: "schedule"), alert: schedule.errors.full_messages.to_sentence
      end
    end

    private

    def schedule_params
      permitted = params.require(:scope_schedule)
                        .permit(:enabled, :interval_minutes, :mode, :bug_bounty, :vdp, platforms: [])
      permitted[:platforms] = Array(permitted[:platforms]).reject(&:blank?)
      permitted
    end
  end
end
