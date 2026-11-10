class AddReviewedAtToEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :entries, :reviewed_at, :datetime
    add_reference :entries, :reviewed_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }, index: true
    add_index :entries, [ :account_id, :date ], where: "reviewed_at IS NULL", name: "index_entries_unreviewed_on_account_and_date"
  end
end
