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

ActiveRecord::Schema[8.1].define(version: 2026_10_20_080000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activities", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.date "occurred_on", null: false
    t.string "title", limit: 255, null: false
    t.string "activity_type", limit: 50, null: false
    t.string "place", limit: 255
    t.integer "amount"
    t.text "memo"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["user_id", "occurred_on"], name: "index_activities_on_user_id_and_occurred_on"
  end

  create_table "activity_emotions", force: :cascade do |t|
    t.bigint "activity_id", null: false
    t.bigint "emotion_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_id", "emotion_id"], name: "index_activity_emotions_on_activity_id_and_emotion_id", unique: true
    t.index ["activity_id"], name: "index_activity_emotions_on_activity_id"
    t.index ["emotion_id"], name: "index_activity_emotions_on_emotion_id"
  end

  create_table "activity_oshis", force: :cascade do |t|
    t.bigint "activity_id", null: false
    t.bigint "oshi_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_id", "oshi_id"], name: "index_activity_oshis_on_activity_id_and_oshi_id", unique: true
    t.index ["activity_id"], name: "index_activity_oshis_on_activity_id"
    t.index ["oshi_id"], name: "index_activity_oshis_on_oshi_id"
  end

  create_table "emotions", force: :cascade do |t|
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_emotions_on_name", unique: true
  end

  create_table "oshi_aliases", force: :cascade do |t|
    t.bigint "oshi_id", null: false
    t.string "alias_name", limit: 255, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alias_name"], name: "index_oshi_aliases_on_alias_name"
    t.index ["oshi_id", "alias_name"], name: "index_oshi_aliases_on_oshi_id_and_alias_name", unique: true
    t.index ["oshi_id"], name: "index_oshi_aliases_on_oshi_id"
  end

  create_table "oshis", force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.string "oshi_type", limit: 50, null: false
    t.string "affiliation", limit: 255
    t.string "status", limit: 20, default: "pending", null: false
    t.bigint "created_by_user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_user_id"], name: "index_oshis_on_created_by_user_id"
    t.index ["name"], name: "index_oshis_on_name"
  end

  create_table "profiles", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "display_name", limit: 50, null: false
    t.text "introduction"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
  end

  create_table "subscription_oshis", force: :cascade do |t|
    t.bigint "subscription_id", null: false
    t.bigint "oshi_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["oshi_id"], name: "index_subscription_oshis_on_oshi_id"
    t.index ["subscription_id", "oshi_id"], name: "index_subscription_oshis_on_subscription_id_and_oshi_id", unique: true
    t.index ["subscription_id"], name: "index_subscription_oshis_on_subscription_id"
  end

  create_table "subscriptions", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "name", limit: 255, null: false
    t.integer "amount", null: false
    t.string "billing_cycle", limit: 20, null: false
    t.date "started_on"
    t.date "ended_on"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "lock_version", default: 0, null: false
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "user_oshis", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.bigint "oshi_id", null: false
    t.string "started_period", limit: 7
    t.string "ended_period", limit: 7
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["oshi_id"], name: "index_user_oshis_on_oshi_id"
    t.index ["user_id", "oshi_id"], name: "index_user_oshis_on_user_id_and_oshi_id", unique: true
    t.index ["user_id"], name: "index_user_oshis_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "activities", "users"
  add_foreign_key "activity_emotions", "activities"
  add_foreign_key "activity_emotions", "emotions"
  add_foreign_key "activity_oshis", "activities"
  add_foreign_key "activity_oshis", "oshis"
  add_foreign_key "oshi_aliases", "oshis"
  add_foreign_key "oshis", "users", column: "created_by_user_id"
  add_foreign_key "profiles", "users"
  add_foreign_key "subscription_oshis", "oshis"
  add_foreign_key "subscription_oshis", "subscriptions"
  add_foreign_key "subscriptions", "users"
  add_foreign_key "user_oshis", "oshis"
  add_foreign_key "user_oshis", "users"
end
