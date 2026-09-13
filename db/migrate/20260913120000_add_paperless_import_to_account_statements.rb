# frozen_string_literal: true

class AddPaperlessImportToAccountStatements < ActiveRecord::Migration[7.2]
  def change
    add_reference :account_statements, :paperless_connection,
                   type: :uuid, null: true, index: true,
                   foreign_key: { to_table: :paperless_connections, on_delete: :nullify }
    add_column :account_statements, :paperless_document_id, :integer

    # Keyed on family_id (never nullified), not paperless_connection_id (nullified when the
    # connection is deleted/replaced) — see chk_account_statements_source below for why.
    add_index :account_statements,
              [ :family_id, :paperless_document_id ],
              unique: true,
              where: "paperless_document_id IS NOT NULL",
              name: "index_account_statements_on_family_paperless_document"

    remove_check_constraint :account_statements,
                            "source IN ('manual_upload')",
                            name: "chk_account_statements_source"
    add_check_constraint :account_statements,
                         "source IN ('manual_upload', 'paperless_import')",
                         name: "chk_account_statements_source"
    add_check_constraint :account_statements,
                         "paperless_document_id IS NULL OR source = 'paperless_import'",
                         name: "chk_account_statements_paperless_document_source"
  end
end
