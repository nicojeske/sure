# frozen_string_literal: true

# Distinguishes the existing transaction-first scan (PaperlessScanFamilyJob) from the new
# document-first sweep (PaperlessSweepDocumentsJob) sharing the same PaperlessScan progress row and
# one-in-progress-per-family index. `added_from` bounds a documents-mode sweep to Paperless
# documents added on/after that date (used by the nightly PaperlessSweepAllJob to stay cheap); left
# null for an unbounded manual sweep of the whole backlog.
class AddModeToPaperlessScans < ActiveRecord::Migration[7.2]
  def change
    add_column :paperless_scans, :mode, :string, null: false, default: "transactions"
    add_column :paperless_scans, :added_from, :date

    add_check_constraint :paperless_scans,
                         "mode IN ('transactions', 'documents')",
                         name: "chk_paperless_scans_mode"
  end
end
