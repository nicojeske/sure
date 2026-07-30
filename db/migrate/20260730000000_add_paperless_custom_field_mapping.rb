# frozen_string_literal: true

class AddPaperlessCustomFieldMapping < ActiveRecord::Migration[7.2]
  def change
    add_column :paperless_connections, :total_amount_field_id, :integer
    add_column :paperless_connections, :net_amount_field_id, :integer
    add_column :paperless_connections, :tax_amount_field_id, :integer
    add_column :paperless_connections, :reference_field_id, :integer
    add_column :paperless_connections, :structured_match_window_days, :integer, null: false, default: 30

    # cached so drawer rows / list pills render without an HTTP call, alongside the existing document_* columns
    add_column :receipt_links, :document_amount, :decimal, precision: 19, scale: 4
    add_column :receipt_links, :document_currency, :string
    add_column :receipt_links, :document_reference, :string
  end
end
