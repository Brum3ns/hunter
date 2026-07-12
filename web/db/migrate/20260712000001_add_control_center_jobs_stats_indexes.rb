class AddControlCenterJobsStatsIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :control_center_jobs, :template_name
    add_index :control_center_jobs, :status
  end
end
