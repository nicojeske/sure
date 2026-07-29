require "test_helper"

class PaperlessScanFamilyJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @connection = paperless_connections(:one)

    # Fixture transactions default to receipt_scanned_at: nil, which would otherwise
    # also match "needs scan" and pollute the count-based assertions below.
    Transaction.update_all(receipt_scanned_at: Time.current)
  end

  test "enqueues a scan for a never-scanned, non-transfer transaction within the lookback window" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")

    assert_enqueued_with(job: PaperlessAutoLinkJob, args: [ entry.transaction.id ]) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "enqueues a scan for a stale, unlinked scan even if already scanned once" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 8.days.ago)

    assert_enqueued_with(job: PaperlessAutoLinkJob, args: [ entry.transaction.id ]) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips a transaction that was scanned recently" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 1.day.ago)

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips a stale scan when a linked receipt already exists" do
    entry = create_transaction(date: 5.days.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, 8.days.ago)
    ReceiptLink.create!(
      transaction_record: entry.transaction,
      paperless_connection: @connection,
      document_id: 999,
      status: "linked"
    )

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips transfer-kind transactions" do
    create_transaction(date: 5.days.ago.to_date, kind: "funds_movement")

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips transactions outside the 90-day lookback window" do
    create_transaction(date: 100.days.ago.to_date, kind: "standard")

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips families without a configured connection" do
    @connection.destroy
    create_transaction(date: 5.days.ago.to_date, kind: "standard")

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "skips families with auto_link_enabled false" do
    @connection.update!(auto_link_enabled: false)
    create_transaction(date: 5.days.ago.to_date, kind: "standard")

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  end

  test "caps the number of enqueued scans per run" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    create_transaction(date: 5.days.ago.to_date, kind: "standard")

    original_cap = PaperlessScanFamilyJob::MAX_TRANSACTIONS_PER_RUN
    silence_warnings { PaperlessScanFamilyJob.const_set(:MAX_TRANSACTIONS_PER_RUN, 1) }

    assert_enqueued_jobs 1, only: PaperlessAutoLinkJob do
      PaperlessScanFamilyJob.perform_now(@family.id)
    end
  ensure
    silence_warnings { PaperlessScanFamilyJob.const_set(:MAX_TRANSACTIONS_PER_RUN, original_cap) }
  end
end
