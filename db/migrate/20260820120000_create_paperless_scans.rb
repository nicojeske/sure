# frozen_string_literal: true

class CreatePaperlessScans < ActiveRecord::Migration[8.1]
  def change
    create_table :paperless_scans, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true, index: false
      t.references :paperless_connection, null: false, type: :uuid, foreign_key: true
      t.string  :status,  null: false, default: "pending" # pending | running | completed | failed
      t.string  :trigger, null: false, default: "manual"  # manual | scheduled
      t.integer :total_count,     null: false, default: 0
      t.integer :processed_count, null: false, default: 0
      t.integer :linked_count,    null: false, default: 0
      t.integer :suggested_count, null: false, default: 0
      t.integer :error_count,     null: false, default: 0
      t.boolean :capped, null: false, default: false
      t.datetime :started_at
      t.datetime :completed_at
      t.text :error
      t.timestamps
    end

    add_check_constraint :paperless_scans,
                         "status IN ('pending','running','completed','failed')",
                         name: "chk_paperless_scans_status"

    # One live scan per family, enforced in the DB — a double-clicked "Scan" button raises
    # RecordNotUnique instead of starting a second concurrent scan of the same transactions.
    add_index :paperless_scans, :family_id, unique: true,
              where: "status IN ('pending','running')",
              name: "index_paperless_scans_on_family_id_in_progress"

    add_index :paperless_scans, [ :family_id, :created_at ]

    # The /receipts list is family-scoped through paperless_connection_id (unique per family)
    # and ordered by created_at — this index serves that query directly.
    add_index :receipt_links, [ :paperless_connection_id, :created_at ]
  end
end
