class AddAssistantEditVersionsToAnsibleResources < ActiveRecord::Migration[8.0]
  def change
    add_column :control_center_ansible_inventories, :lock_version, :integer,
      null: false, default: 0
    add_column :control_center_ansible_variable_sets, :lock_version, :integer,
      null: false, default: 0
    add_column :control_center_ansible_variables, :lock_version, :integer,
      null: false, default: 0
  end
end
