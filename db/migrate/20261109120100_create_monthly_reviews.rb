class CreateMonthlyReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :monthly_reviews, id: :uuid do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.text :notes
      t.datetime :completed_at
      t.datetime :prefetched_at

      t.timestamps
    end

    add_index :monthly_reviews, [ :family_id, :start_date ], unique: true
  end
end
