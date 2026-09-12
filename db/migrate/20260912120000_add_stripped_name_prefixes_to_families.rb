class AddStrippedNamePrefixesToFamilies < ActiveRecord::Migration[7.2]
  def change
    add_column :families, :stripped_name_prefixes, :string, array: true, default: []
  end
end
