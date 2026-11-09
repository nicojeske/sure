class CreateTransactionAnnotationSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :transaction_annotation_suggestions, id: :uuid do |t|
      t.references :entry, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :receipt_link, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :source, null: false
      t.string :status, null: false, default: "pending"
      t.string :input_hash, null: false
      t.text :hint_text
      t.jsonb :payload, null: false, default: {}
      t.jsonb :snapshot
      t.jsonb :applied_fields
      t.text :error

      t.timestamps
    end

    add_index :transaction_annotation_suggestions, [ :entry_id, :input_hash ], unique: true, name: "index_annotation_suggestions_on_entry_and_input_hash"
    add_check_constraint :transaction_annotation_suggestions, "source IN ('receipt', 'hint', 'learned')", name: "chk_annotation_suggestions_source"
    add_check_constraint :transaction_annotation_suggestions, "status IN ('pending', 'ready', 'failed', 'applied', 'reverted')", name: "chk_annotation_suggestions_status"
  end
end
