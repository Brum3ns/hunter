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

ActiveRecord::Schema[8.1].define(version: 2026_07_12_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
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
  add_foreign_key "trashes", "users"
end
