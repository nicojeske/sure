class AddAiContentLanguageToFamilies < ActiveRecord::Migration[8.1]
  def change
    add_column :families, :ai_content_language, :string
  end
end
