class AddControlCenterWriteEnabledToAssistantSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :assistant_settings, :control_center_write_enabled, :boolean, default: true, null: false
  end
end
