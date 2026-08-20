require "test_helper"

class PaperlessScanFamilyJobTest < ActiveJob::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @connection = paperless_connections(:one)

    # Fixture transactions default to receipt_scanned_at: nil, which would otherwise also match
    # "needs scan" and pollute the count-based assertions below.
    Transaction.update_all(receipt_scanned_at: Time.current)
  end

  test "records progress and outcome counts for a completed run" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    create_transaction(date: 6.days.ago.to_date, kind: "standard")
    stub_matcher_outcomes(:linked, :suggested)

    scan = create_scan
    PaperlessScanFamilyJob.perform_now(scan.id)
    scan.reload

    assert_equal "completed", scan.status
    assert_equal 2, scan.total_count
    assert_equal 2, scan.processed_count
    assert_equal 1, scan.linked_count
    assert_equal 1, scan.suggested_count
    assert_equal 0, scan.error_count
    assert scan.completed_at.present?
  end

  test "runs even when auto_link_enabled is off" do
    @connection.update!(auto_link_enabled: false)
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    stub_matcher_outcomes(:linked)

    scan = create_scan
    PaperlessScanFamilyJob.perform_now(scan.id)

    assert_equal "completed", scan.reload.status
    assert_equal 1, scan.linked_count
  end

  test "fails the scan when the connection is not configured" do
    @connection.update_column(:api_token, nil)
    scan = create_scan

    PaperlessScanFamilyJob.perform_now(scan.id)

    assert_equal "failed", scan.reload.status
    assert scan.error.present?
  end

  test "flags a run that hits the per-run transaction cap" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    create_transaction(date: 6.days.ago.to_date, kind: "standard")
    stub_matcher_outcomes(:none)

    scan = create_scan
    with_max_transactions(1) { PaperlessScanFamilyJob.perform_now(scan.id) }
    scan.reload

    assert scan.capped?
    assert_equal 1, scan.total_count
    assert_equal 1, scan.processed_count
  end

  test "counts a per-transaction provider error and keeps going" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    create_transaction(date: 6.days.ago.to_date, kind: "standard")

    PaperlessConnection::Matcher.any_instance.stubs(:match!)
      .raises(provider_error(:server_error))
      .then.returns(matcher_result(:linked))

    scan = create_scan
    PaperlessScanFamilyJob.perform_now(scan.id)
    scan.reload

    assert_equal "completed", scan.status
    assert_equal 1, scan.error_count
    assert_equal 1, scan.linked_count
    assert_equal 2, scan.processed_count
  end

  test "aborts the whole scan on an unauthorized provider error" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    create_transaction(date: 6.days.ago.to_date, kind: "standard")
    PaperlessConnection::Matcher.any_instance.stubs(:match!).raises(provider_error(:unauthorized))

    scan = create_scan
    PaperlessScanFamilyJob.perform_now(scan.id)
    scan.reload

    assert_equal "failed", scan.status
    assert_equal 1, scan.error_count
    assert_equal 0, scan.processed_count
  end

  test "does nothing for a scan that is no longer pending" do
    create_transaction(date: 5.days.ago.to_date, kind: "standard")
    PaperlessConnection::Matcher.any_instance.expects(:match!).never

    scan = create_scan
    scan.update!(status: "completed")

    PaperlessScanFamilyJob.perform_now(scan.id)
  end

  private
    def create_scan
      PaperlessScan.create!(family: @family, paperless_connection: @connection, trigger: "manual")
    end

    def matcher_result(outcome)
      PaperlessConnection::Matcher::Result.new(outcome: outcome, candidates: [])
    end

    def stub_matcher_outcomes(*outcomes)
      stub = PaperlessConnection::Matcher.any_instance.stubs(:match!)
      outcomes.each_with_index do |outcome, index|
        stub = stub.then if index.positive?
        stub = stub.returns(matcher_result(outcome))
      end
    end

    def provider_error(error_type)
      Provider::Paperless::Error.new("paperless boom", error_type)
    end

    def with_max_transactions(limit)
      original = PaperlessConnection::MAX_TRANSACTIONS_PER_RUN
      silence_warnings { PaperlessConnection.const_set(:MAX_TRANSACTIONS_PER_RUN, limit) }
      yield
    ensure
      silence_warnings { PaperlessConnection.const_set(:MAX_TRANSACTIONS_PER_RUN, original) }
    end
end
