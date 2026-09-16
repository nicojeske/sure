# frozen_string_literal: true

# Date window used by the document-first sweep (PaperlessConnection::DocumentMatcher), separate
# from match_window_days (the transaction-first Matcher's window) because a document sweep needs a
# much wider default: historical receipts are commonly filed weeks away from the transaction date,
# whereas the forward per-transaction scan runs the same day or shortly after.
class AddSweepWindowDaysToPaperlessConnections < ActiveRecord::Migration[7.2]
  def change
    add_column :paperless_connections, :sweep_window_days, :integer, null: false, default: 30
  end
end
