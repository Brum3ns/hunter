class AddLockVersionsToAuthoringArtifacts < ActiveRecord::Migration[8.1]
  def change
    add_column :control_center_templates, :lock_version, :integer, null: false, default: 0
    add_column :control_center_ansible_playbooks, :lock_version, :integer, null: false, default: 0
  end
end
