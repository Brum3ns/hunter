class CreateControlCenterAnsibleExecution < ActiveRecord::Migration[8.1]
  def change
    create_table :control_center_ansible_run_groups do |t|
      t.string :status, null: false, default: "queued"
      t.string :execution_mode, null: false, default: "sequential"
      t.string :failure_policy, null: false, default: "stop"
      t.integer :concurrency_limit, null: false, default: 1
      t.references :inventory,
        foreign_key: { to_table: :control_center_ansible_inventories, on_delete: :nullify }
      t.references :credential,
        foreign_key: { to_table: :control_center_ansible_credentials, on_delete: :nullify }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :execution_payload
      t.jsonb :launch_snapshot, null: false, default: {}
      t.datetime :cancel_requested_at
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :control_center_ansible_run_groups, %i[status created_at],
      name: "idx_ansible_run_groups_status_created"

    create_table :control_center_ansible_runs do |t|
      t.references :run_group, null: false,
        foreign_key: { to_table: :control_center_ansible_run_groups }
      t.references :playbook,
        foreign_key: { to_table: :control_center_ansible_playbooks, on_delete: :nullify }
      t.integer :position, null: false
      t.string :status, null: false, default: "queued"
      t.text :playbook_yaml, null: false
      t.text :inventory_yaml, null: false
      t.text :known_hosts, null: false
      t.jsonb :variable_audit, null: false, default: {}
      t.jsonb :secret_variable_names, null: false, default: []
      t.string :playbook_name, null: false
      t.string :inventory_name, null: false
      t.string :credential_name, null: false
      t.string :credential_fingerprint
      t.string :host_limit
      t.boolean :check_mode, null: false, default: false
      t.integer :timeout_seconds, null: false
      t.string :error_code
      t.text :error_detail
      t.integer :exit_status
      t.integer :ok_count, null: false, default: 0
      t.integer :changed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :unreachable_count, null: false, default: 0
      t.bigint :stored_event_bytes, null: false, default: 0
      t.boolean :truncated, null: false, default: false
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :lease_digest
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.datetime :queued_at
      t.datetime :claim_deadline
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :cancel_requested_at
      t.timestamps
    end
    add_index :control_center_ansible_runs, %i[status queued_at id],
      name: "idx_ansible_runs_claim_order"
    add_index :control_center_ansible_runs, %i[run_group_id position], unique: true,
      name: "idx_ansible_runs_group_position"

    create_table :control_center_ansible_run_events do |t|
      t.references :run, null: false, foreign_key: { to_table: :control_center_ansible_runs }
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :event_uuid, null: false
      t.string :parent_uuid
      t.bigint :counter, null: false
      t.string :event_type, null: false
      t.string :play
      t.string :task
      t.string :host
      t.datetime :event_time
      t.text :stdout
      t.jsonb :event_data, null: false, default: {}
      t.boolean :truncated, null: false, default: false
      t.timestamps
    end
    add_index :control_center_ansible_run_events, %i[run_id event_uuid], unique: true,
      name: "idx_ansible_run_events_uuid"
    add_index :control_center_ansible_run_events, %i[run_id counter], unique: true,
      name: "idx_ansible_run_events_counter"

    create_table :control_center_ansible_executor_tasks do |t|
      t.string :kind, null: false
      t.string :status, null: false, default: "queued"
      t.references :inventory,
        foreign_key: { to_table: :control_center_ansible_inventories, on_delete: :nullify }
      t.references :playbook,
        foreign_key: { to_table: :control_center_ansible_playbooks, on_delete: :nullify }
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.text :execution_payload
      t.jsonb :result, null: false, default: {}
      t.string :error_code
      t.text :error_detail
      t.references :runner, foreign_key: { on_delete: :nullify }
      t.string :lease_digest
      t.datetime :lease_expires_at
      t.datetime :heartbeat_at
      t.datetime :claim_deadline, null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :control_center_ansible_executor_tasks, %i[status created_at],
      name: "idx_ansible_executor_tasks_claim_order"
  end
end
