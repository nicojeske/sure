class CreateRuleSuggestionDismissals < ActiveRecord::Migration[8.1]
  def change
    create_table :rule_suggestion_dismissals, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :pattern_key, null: false

      t.timestamps
    end

    add_index :rule_suggestion_dismissals, %i[family_id pattern_key], unique: true
  end
end
