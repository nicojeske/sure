# frozen_string_literal: true

class CreatePaperlessConnectionsAndReceiptLinks < ActiveRecord::Migration[7.2]
  def change
    create_table :paperless_connections, id: :uuid do |t|
      t.references :family, null: false, type: :uuid, foreign_key: true, index: { unique: true }
      t.text     :base_url, null: false
      t.text     :api_token
      t.boolean  :verify_ssl,        null: false, default: true
      t.boolean  :auto_link_enabled, null: false, default: true
      t.integer  :match_window_days, null: false, default: 3
      t.decimal  :min_auto_link_score, null: false, default: 0.9, precision: 4, scale: 3
      t.datetime :last_connected_at
      t.datetime :last_error_at
      t.text     :last_error
      t.timestamps
    end

    create_table :receipt_links, id: :uuid do |t|
      t.references :transaction, null: false, type: :uuid, foreign_key: true, index: false
      t.references :paperless_connection, null: false, type: :uuid, foreign_key: true
      t.integer :document_id, null: false
      t.string  :status, null: false, default: "suggested" # linked | suggested | dismissed
      t.string  :source, null: false, default: "auto"       # auto | manual
      t.decimal :score, precision: 4, scale: 3
      t.jsonb   :match_reasons, null: false, default: {}
      # cached Paperless metadata so lists and pills render without an HTTP call
      t.string :document_title
      t.date   :document_created_on
      t.string :document_correspondent
      t.string :document_mime_type
      t.timestamps
    end
    add_index :receipt_links, [ :transaction_id, :document_id ], unique: true
    add_index :receipt_links, [ :transaction_id, :status ]
    add_check_constraint :receipt_links, "status IN ('linked','suggested','dismissed')",
                          name: "chk_receipt_links_status"

    add_column :transactions, :receipt_scanned_at, :datetime
    add_index :transactions, :receipt_scanned_at, where: "receipt_scanned_at IS NULL",
              name: "index_transactions_unscanned_receipts"
  end
end
