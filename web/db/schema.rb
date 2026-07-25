# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_07_23_030001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "cve_filter", default: {}, null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "scopes", default: ["*"], null: false, array: true
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "control_center_ansible_credentials", force: :cascade do |t|
    t.string "auth_type", null: false
    t.text "become_password"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.text "private_key"
    t.text "private_key_passphrase"
    t.string "public_key_fingerprint"
    t.text "ssh_password"
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index "lower((name)::text)", name: "idx_ansible_credentials_lower_name", unique: true
    t.index ["created_by_id"], name: "index_control_center_ansible_credentials_on_created_by_id"
  end

  create_table "control_center_ansible_executor_tasks", force: :cascade do |t|
    t.datetime "claim_deadline", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.string "error_code"
    t.text "error_detail"
    t.text "execution_payload"
    t.datetime "heartbeat_at"
    t.bigint "inventory_id"
    t.string "kind", null: false
    t.string "lease_digest"
    t.datetime "lease_expires_at"
    t.bigint "playbook_id"
    t.jsonb "result", default: {}, null: false
    t.bigint "runner_id"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_control_center_ansible_executor_tasks_on_created_by_id"
    t.index ["inventory_id"], name: "index_control_center_ansible_executor_tasks_on_inventory_id"
    t.index ["playbook_id"], name: "index_control_center_ansible_executor_tasks_on_playbook_id"
    t.index ["runner_id"], name: "index_control_center_ansible_executor_tasks_on_runner_id"
    t.index ["status", "created_at"], name: "idx_ansible_executor_tasks_claim_order"
  end

  create_table "control_center_ansible_inventories", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.bigint "default_credential_id"
    t.text "description"
    t.jsonb "host_key_fingerprints", default: {}, null: false
    t.text "known_hosts"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.text "yaml_content", null: false
    t.index "lower((name)::text)", name: "idx_ansible_inventories_lower_name", unique: true
    t.index ["created_by_id"], name: "index_control_center_ansible_inventories_on_created_by_id"
    t.index ["default_credential_id"], name: "idx_on_default_credential_id_e97a9f9e8e"
  end

  create_table "control_center_ansible_inventory_variable_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "inventory_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "variable_set_id", null: false
    t.index ["inventory_id", "variable_set_id"], name: "idx_ansible_inventory_variable_sets_unique", unique: true
    t.index ["inventory_id"], name: "idx_on_inventory_id_ab4dc86d2f"
    t.index ["variable_set_id"], name: "idx_on_variable_set_id_37a6f0fa33"
  end

  create_table "control_center_ansible_playbook_variable_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "playbook_id", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "variable_set_id", null: false
    t.index ["playbook_id", "variable_set_id"], name: "idx_ansible_playbook_variable_sets_unique", unique: true
    t.index ["playbook_id"], name: "idx_on_playbook_id_cb52d9ddb7"
    t.index ["variable_set_id"], name: "idx_on_variable_set_id_a2f486ee66"
  end

  create_table "control_center_ansible_playbooks", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.text "yaml_content", null: false
    t.index "lower((name)::text)", name: "idx_ansible_playbooks_lower_name", unique: true
    t.index ["created_by_id"], name: "index_control_center_ansible_playbooks_on_created_by_id"
  end

  create_table "control_center_ansible_run_events", force: :cascade do |t|
    t.bigint "counter", null: false
    t.datetime "created_at", null: false
    t.jsonb "event_data", default: {}, null: false
    t.datetime "event_time"
    t.string "event_type", null: false
    t.string "event_uuid", null: false
    t.string "host"
    t.string "parent_uuid"
    t.string "play"
    t.bigint "run_id", null: false
    t.bigint "runner_id"
    t.text "stdout"
    t.string "task"
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["run_id", "counter"], name: "idx_ansible_run_events_counter", unique: true
    t.index ["run_id", "event_uuid"], name: "idx_ansible_run_events_uuid", unique: true
    t.index ["run_id"], name: "index_control_center_ansible_run_events_on_run_id"
    t.index ["runner_id"], name: "index_control_center_ansible_run_events_on_runner_id"
  end

  create_table "control_center_ansible_run_groups", force: :cascade do |t|
    t.datetime "cancel_requested_at"
    t.datetime "completed_at"
    t.integer "concurrency_limit", default: 1, null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.bigint "credential_id"
    t.string "execution_mode", default: "sequential", null: false
    t.text "execution_payload"
    t.string "failure_policy", default: "stop", null: false
    t.bigint "inventory_id"
    t.jsonb "launch_snapshot", default: {}, null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_control_center_ansible_run_groups_on_created_by_id"
    t.index ["credential_id"], name: "index_control_center_ansible_run_groups_on_credential_id"
    t.index ["inventory_id"], name: "index_control_center_ansible_run_groups_on_inventory_id"
    t.index ["status", "created_at"], name: "idx_ansible_run_groups_status_created"
  end

  create_table "control_center_ansible_runs", force: :cascade do |t|
    t.datetime "cancel_requested_at"
    t.integer "changed_count", default: 0, null: false
    t.boolean "check_mode", default: false, null: false
    t.datetime "claim_deadline"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "credential_fingerprint"
    t.string "credential_name", null: false
    t.string "error_code"
    t.text "error_detail"
    t.integer "exit_status"
    t.integer "failed_count", default: 0, null: false
    t.datetime "heartbeat_at"
    t.string "host_limit"
    t.string "inventory_name", null: false
    t.text "inventory_yaml", null: false
    t.text "known_hosts", null: false
    t.string "lease_digest"
    t.datetime "lease_expires_at"
    t.integer "ok_count", default: 0, null: false
    t.bigint "playbook_id"
    t.string "playbook_name", null: false
    t.text "playbook_yaml", null: false
    t.integer "position", null: false
    t.datetime "queued_at"
    t.bigint "run_group_id", null: false
    t.bigint "runner_id"
    t.jsonb "secret_variable_names", default: [], null: false
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.bigint "stored_event_bytes", default: 0, null: false
    t.integer "timeout_seconds", null: false
    t.boolean "truncated", default: false, null: false
    t.integer "unreachable_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.jsonb "variable_audit", default: {}, null: false
    t.index ["playbook_id"], name: "index_control_center_ansible_runs_on_playbook_id"
    t.index ["run_group_id", "position"], name: "idx_ansible_runs_group_position", unique: true
    t.index ["run_group_id"], name: "index_control_center_ansible_runs_on_run_group_id"
    t.index ["runner_id"], name: "index_control_center_ansible_runs_on_runner_id"
    t.index ["status", "queued_at", "id"], name: "idx_ansible_runs_claim_order"
  end

  create_table "control_center_ansible_variable_sets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_id", null: false
    t.text "description"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index "lower((name)::text)", name: "idx_ansible_variable_sets_lower_name", unique: true
    t.index ["created_by_id"], name: "index_control_center_ansible_variable_sets_on_created_by_id"
  end

  create_table "control_center_ansible_variables", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.boolean "secret", default: false, null: false
    t.text "serialized_value", null: false
    t.datetime "updated_at", null: false
    t.string "value_type", null: false
    t.bigint "variable_set_id", null: false
    t.index ["variable_set_id", "name"], name: "idx_ansible_variables_set_name", unique: true
    t.index ["variable_set_id", "position"], name: "idx_ansible_variables_set_position"
    t.index ["variable_set_id"], name: "index_control_center_ansible_variables_on_variable_set_id"
  end

  create_table "control_center_jobs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "created_by"
    t.integer "exit_status"
    t.string "queue_name", default: "test", null: false
    t.string "status", default: "pending", null: false
    t.text "stderr"
    t.text "stdout"
    t.integer "target_count", default: 0, null: false
    t.string "template_name", null: false
    t.jsonb "template_snapshot", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_control_center_jobs_on_created_at"
    t.index ["status"], name: "index_control_center_jobs_on_status"
    t.index ["template_name"], name: "index_control_center_jobs_on_template_name"
  end

  create_table "control_center_templates", force: :cascade do |t|
    t.jsonb "commands", default: [], null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.text "description", default: "", null: false
    t.string "kind", default: "cmdscript", null: false
    t.string "name", null: false
    t.string "output"
    t.jsonb "tags", default: [], null: false
    t.jsonb "target"
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_control_center_templates_on_name", unique: true
  end

  create_table "favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "program_sid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "program_sid"], name: "index_favorites_on_user_id_and_program_sid", unique: true
    t.index ["user_id"], name: "index_favorites_on_user_id"
  end

  create_table "mongo_stream_cursors", force: :cascade do |t|
    t.string "collection", null: false
    t.datetime "created_at", null: false
    t.jsonb "resume_token", default: {}, null: false
    t.datetime "updated_at", null: false
    t.index ["collection"], name: "index_mongo_stream_cursors_on_collection", unique: true
  end

  create_table "monitor_configs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.integer "interval_seconds", default: 300, null: false
    t.datetime "last_tick_at"
    t.datetime "next_tick_at"
    t.jsonb "platforms", default: [], null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_monitor_configs_on_user_id", unique: true
  end

  create_table "program_changes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "detected_at", null: false
    t.string "kind", null: false
    t.jsonb "new_value"
    t.jsonb "old_value"
    t.string "platform"
    t.string "program_name"
    t.string "program_sid"
    t.bigint "scope_run_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["scope_run_id"], name: "index_program_changes_on_scope_run_id"
    t.index ["user_id", "detected_at"], name: "index_program_changes_on_user_id_and_detected_at"
    t.index ["user_id", "platform"], name: "index_program_changes_on_user_id_and_platform"
    t.index ["user_id"], name: "index_program_changes_on_user_id"
  end

  create_table "program_views", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "program_sid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.datetime "viewed_at", null: false
    t.index ["user_id", "program_sid"], name: "index_program_views_on_user_id_and_program_sid", unique: true
    t.index ["user_id", "viewed_at"], name: "index_program_views_on_user_id_and_viewed_at"
    t.index ["user_id"], name: "index_program_views_on_user_id"
  end

  create_table "runner_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "claimed_at"
    t.text "command", null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "error"
    t.integer "exit_status"
    t.datetime "finished_at"
    t.string "kind", null: false
    t.boolean "output_truncated", default: false, null: false
    t.bigint "requested_by_id", null: false
    t.bigint "runner_id"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.text "stderr"
    t.text "stdout"
    t.datetime "updated_at", null: false
    t.string "vulnerability_id", null: false
    t.index ["requested_by_id"], name: "index_runner_jobs_on_requested_by_id"
    t.index ["runner_id"], name: "index_runner_jobs_on_runner_id"
    t.index ["status", "kind", "created_at"], name: "index_runner_jobs_on_status_and_kind_and_created_at"
  end

  create_table "runners", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "kinds", default: [], null: false, array: true
    t.datetime "last_seen_at"
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_runners_on_name", unique: true
    t.index ["token_digest"], name: "index_runners_on_token_digest", unique: true
  end

  create_table "scope_runs", force: :cascade do |t|
    t.boolean "bug_bounty", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "error_class"
    t.integer "exit_status"
    t.datetime "finished_at"
    t.string "kind", null: false
    t.string "mode"
    t.string "platform"
    t.jsonb "programs", default: [], null: false
    t.datetime "started_at"
    t.text "stderr_excerpt"
    t.integer "stdout_bytes"
    t.text "stdout_excerpt"
    t.boolean "success"
    t.string "trigger", default: "manual", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.boolean "vdp", default: false, null: false
    t.index ["kind", "platform"], name: "index_scope_runs_on_kind_and_platform"
    t.index ["started_at"], name: "index_scope_runs_on_started_at"
    t.index ["user_id"], name: "index_scope_runs_on_user_id"
  end

  create_table "scope_schedules", force: :cascade do |t|
    t.boolean "bug_bounty", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.integer "interval_minutes", default: 60, null: false
    t.datetime "last_run_at"
    t.string "mode", default: "all", null: false
    t.datetime "next_run_at"
    t.jsonb "platforms", default: [], null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.boolean "vdp", default: false, null: false
    t.index ["user_id"], name: "index_scope_schedules_on_user_id", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "sitemap_endpoints", force: :cascade do |t|
    t.bigint "content_length"
    t.string "content_type"
    t.string "crawl_mongo_id"
    t.datetime "created_at", null: false
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "method", null: false
    t.string "origin", null: false
    t.text "path", null: false
    t.datetime "removed_at"
    t.integer "status_code"
    t.bigint "target_id"
    t.datetime "updated_at", null: false
    t.text "url", null: false
    t.binary "url_digest", null: false
    t.index ["origin", "url_digest"], name: "idx_sitemap_endpoints_unmatched_digest", unique: true, where: "(target_id IS NULL)"
    t.index ["origin"], name: "idx_sitemap_endpoints_unmatched_origin", where: "(target_id IS NULL)"
    t.index ["target_id", "path"], name: "index_sitemap_endpoints_on_target_id_and_path"
    t.index ["target_id", "removed_at"], name: "index_sitemap_endpoints_on_target_id_and_removed_at"
    t.index ["target_id", "url_digest"], name: "idx_sitemap_endpoints_matched_digest", unique: true
    t.index ["target_id"], name: "index_sitemap_endpoints_on_target_id"
  end

  create_table "sitemap_targets", force: :cascade do |t|
    t.string "alive_mongo_id"
    t.datetime "created_at", null: false
    t.datetime "first_seen_at", null: false
    t.string "host", null: false
    t.datetime "last_seen_at", null: false
    t.string "origin", null: false
    t.integer "port", null: false
    t.string "program"
    t.datetime "removed_at"
    t.string "scheme", null: false
    t.datetime "updated_at", null: false
    t.index ["host"], name: "index_sitemap_targets_on_host"
    t.index ["origin"], name: "index_sitemap_targets_on_origin", unique: true
    t.index ["program"], name: "index_sitemap_targets_on_program"
    t.index ["removed_at"], name: "index_sitemap_targets_on_removed_at"
  end

  create_table "trashes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "program_sid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "program_sid"], name: "index_trashes_on_user_id_and_program_sid", unique: true
    t.index ["user_id"], name: "index_trashes_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "api_tokens", "users"
  add_foreign_key "control_center_ansible_credentials", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_executor_tasks", "control_center_ansible_inventories", column: "inventory_id", on_delete: :nullify
  add_foreign_key "control_center_ansible_executor_tasks", "control_center_ansible_playbooks", column: "playbook_id", on_delete: :nullify
  add_foreign_key "control_center_ansible_executor_tasks", "runners", on_delete: :nullify
  add_foreign_key "control_center_ansible_executor_tasks", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_inventories", "control_center_ansible_credentials", column: "default_credential_id"
  add_foreign_key "control_center_ansible_inventories", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_inventory_variable_sets", "control_center_ansible_inventories", column: "inventory_id"
  add_foreign_key "control_center_ansible_inventory_variable_sets", "control_center_ansible_variable_sets", column: "variable_set_id"
  add_foreign_key "control_center_ansible_playbook_variable_sets", "control_center_ansible_playbooks", column: "playbook_id"
  add_foreign_key "control_center_ansible_playbook_variable_sets", "control_center_ansible_variable_sets", column: "variable_set_id"
  add_foreign_key "control_center_ansible_playbooks", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_run_events", "control_center_ansible_runs", column: "run_id"
  add_foreign_key "control_center_ansible_run_events", "runners", on_delete: :nullify
  add_foreign_key "control_center_ansible_run_groups", "control_center_ansible_credentials", column: "credential_id", on_delete: :nullify
  add_foreign_key "control_center_ansible_run_groups", "control_center_ansible_inventories", column: "inventory_id", on_delete: :nullify
  add_foreign_key "control_center_ansible_run_groups", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_runs", "control_center_ansible_playbooks", column: "playbook_id", on_delete: :nullify
  add_foreign_key "control_center_ansible_runs", "control_center_ansible_run_groups", column: "run_group_id"
  add_foreign_key "control_center_ansible_runs", "runners", on_delete: :nullify
  add_foreign_key "control_center_ansible_variable_sets", "users", column: "created_by_id"
  add_foreign_key "control_center_ansible_variables", "control_center_ansible_variable_sets", column: "variable_set_id"
  add_foreign_key "favorites", "users"
  add_foreign_key "monitor_configs", "users"
  add_foreign_key "program_changes", "scope_runs"
  add_foreign_key "program_changes", "users"
  add_foreign_key "program_views", "users"
  add_foreign_key "runner_jobs", "runners"
  add_foreign_key "runner_jobs", "users", column: "requested_by_id"
  add_foreign_key "scope_runs", "users"
  add_foreign_key "scope_schedules", "users"
  add_foreign_key "sessions", "users"
  add_foreign_key "sitemap_endpoints", "sitemap_targets", column: "target_id", on_delete: :cascade
  add_foreign_key "trashes", "users"
end
