class AddAssistantCapabilitySettings < ActiveRecord::Migration[8.0]
  def change
    add_column :assistant_settings, :operational_access_enabled, :boolean,
      null: false, default: true
    add_column :assistant_settings, :disabled_capability_tools, :jsonb,
      null: false, default: []
    add_column :assistant_settings, :disabled_capability_effects, :jsonb,
      null: false, default: []
    add_column :assistant_settings, :disabled_capability_modules, :jsonb,
      null: false, default: []
  end
end
