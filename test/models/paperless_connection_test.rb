require "test_helper"

class PaperlessConnectionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @connection = paperless_connections(:one)

    # Fixture transactions default to receipt_scanned_at: nil, which would otherwise also match
    # "needs scan" and pollute the count-based assertions below.
    Transaction.update_all(receipt_scanned_at: Time.current)
  end

  test "includes a never-scanned, non-transfer transaction inside the lookback window" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")

    assert_includes @connection.transactions_needing_scan, entry.transaction
  end

  test "includes a stale scan with nothing linked" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 8.days.ago)

    assert_includes @connection.transactions_needing_scan, entry.transaction
  end

  test "excludes a transaction scanned recently" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 1.day.ago)

    assert_not_includes @connection.transactions_needing_scan, entry.transaction
  end

  test "excludes a stale scan that already has a linked receipt" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 8.days.ago)
    ReceiptLink.create!(
      transaction_record: entry.transaction,
      paperless_connection: @connection,
      document_id: 999,
      status: "linked"
    )

    assert_not_includes @connection.transactions_needing_scan, entry.transaction
  end

  test "excludes transfer-kind transactions" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "funds_movement")

    assert_not_includes @connection.transactions_needing_scan, entry.transaction
  end

  test "excludes transactions outside the lookback window" do
    entry = create_transaction(date: 100.days.ago.to_date, kind: "standard")

    assert_not_includes @connection.transactions_needing_scan, entry.transaction
  end
end
