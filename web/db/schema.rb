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

ActiveRecord::Schema[8.1].define(version: 2026_07_09_000003) do
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

  create_table "favorites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "program_sid", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "program_sid"], name: "index_favorites_on_user_id_and_program_sid", unique: true
    t.index ["user_id"], name: "index_favorites_on_user_id"
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
  add_foreign_key "program_views", "users"
  add_foreign_key "runner_jobs", "runners"
  add_foreign_key "runner_jobs", "users", column: "requested_by_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "trashes", "users"
end
