class CreateControlCenterAnsibleCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_credentials do |t|
      t.string :name, null: false
      t.string :auth_type, null: false
      t.string :username, null: false
      t.text :private_key
      t.text :ssh_password
      t.text :private_key_passphrase
      t.text :become_password
      t.string :public_key_fingerprint
      t.references :created_by, foreign_key: { to_table: :users }, null: false
      t.datetime :last_used_at
      t.timestamps
    end

    add_index :control_center_ansible_credentials, "lower(name)", unique: true,
      name: "idx_ansible_credentials_lower_name"
  end
end
