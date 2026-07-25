class CreateControlCenterAnsibleAuthoring < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_playbooks do |t|
      t.string :name, null: false
      t.text :description
      t.text :yaml_content, null: false
      t.string :checksum, null: false
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_playbooks, "lower(name)", unique: true,
      name: "idx_ansible_playbooks_lower_name"

    create_table :control_center_ansible_inventories do |t|
      t.string :name, null: false
      t.text :description
      t.text :yaml_content, null: false
      t.string :checksum, null: false
      t.references :default_credential,
        foreign_key: { to_table: :control_center_ansible_credentials }
      t.text :known_hosts
      t.jsonb :host_key_fingerprints, null: false, default: {}
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_inventories, "lower(name)", unique: true,
      name: "idx_ansible_inventories_lower_name"

    create_table :control_center_ansible_variable_sets do |t|
      t.string :name, null: false
      t.text :description
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :control_center_ansible_variable_sets, "lower(name)", unique: true,
      name: "idx_ansible_variable_sets_lower_name"

    create_table :control_center_ansible_variables do |t|
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.string :name, null: false
      t.string :value_type, null: false
      t.text :serialized_value, null: false
      t.boolean :secret, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_variables, %i[variable_set_id name], unique: true,
      name: "idx_ansible_variables_set_name"
    add_index :control_center_ansible_variables, %i[variable_set_id position],
      name: "idx_ansible_variables_set_position"

    create_table :control_center_ansible_playbook_variable_sets do |t|
      t.references :playbook, null: false,
        foreign_key: { to_table: :control_center_ansible_playbooks }
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_playbook_variable_sets,
      %i[playbook_id variable_set_id], unique: true,
      name: "idx_ansible_playbook_variable_sets_unique"

    create_table :control_center_ansible_inventory_variable_sets do |t|
      t.references :inventory, null: false,
        foreign_key: { to_table: :control_center_ansible_inventories }
      t.references :variable_set, null: false,
        foreign_key: { to_table: :control_center_ansible_variable_sets }
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :control_center_ansible_inventory_variable_sets,
      %i[inventory_id variable_set_id], unique: true,
      name: "idx_ansible_inventory_variable_sets_unique"
  end
end
