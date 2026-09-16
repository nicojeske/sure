require "test_helper"

class PaperlessSweepDocumentsJobTest < ActiveJob::TestCase
  setup do
    @family = families(:dylan_family)
    @connection = paperless_connections(:one)
  end

  test "records progress and outcome counts for a completed run" do
    stub_search([ document(1), document(2) ])
    stub_matcher_outcomes(:linked, :suggested)

    scan = create_scan
    PaperlessSweepDocumentsJob.perform_now(scan.id)
    scan.reload

    assert_equal "completed", scan.status
    assert_equal 2, scan.total_count
    assert_equal 2, scan.processed_count
    assert_equal 1, scan.linked_count
    assert_equal 1, scan.suggested_count
    assert_equal 0, scan.error_count
    assert scan.completed_at.present?
  end

  test "skips documents that already have a linked ReceiptLink" do
    transaction = create_transaction
    ReceiptLink.create!(
      transaction_record: transaction, paperless_connection: @connection,
      document_id: 1, status: "linked", source: "manual"
    )
    stub_search([ document(1), document(2) ])
    PaperlessConnection::DocumentMatcher.any_instance.expects(:match!).once
      .with { |doc| doc["id"] == 2 }
      .returns(matcher_result(:linked))

    scan = create_scan
    PaperlessSweepDocumentsJob.perform_now(scan.id)
    scan.reload

    assert_equal "completed", scan.status
    assert_equal 2, scan.processed_count
    assert_equal 1, scan.linked_count
  end

  test "runs even when auto_link_enabled is off" do
    @connection.update!(auto_link_enabled: false)
    stub_search([ document(1) ])
    stub_matcher_outcomes(:linked)

    scan = create_scan
    PaperlessSweepDocumentsJob.perform_now(scan.id)

    assert_equal "completed", scan.reload.status
    assert_equal 1, scan.linked_count
  end

  test "fails the scan when the connection is not configured" do
    @connection.update_column(:api_token, nil)
    scan = create_scan

    PaperlessSweepDocumentsJob.perform_now(scan.id)

    assert_equal "failed", scan.reload.status
    assert scan.error.present?
  end

  test "flags a run that hits the per-run document cap" do
    Provider::Paperless.any_instance.stubs(:search_documents).returns({ "count" => 5, "results" => [ document(1) ] })
    stub_matcher_outcomes(:none)

    scan = create_scan
    with_max_documents(1) { PaperlessSweepDocumentsJob.perform_now(scan.id) }
    scan.reload

    assert scan.capped?
    assert_equal 1, scan.total_count
    assert_equal 1, scan.processed_count
  end

  test "counts a per-document provider error and keeps going" do
    stub_search([ document(1), document(2) ])
    PaperlessConnection::DocumentMatcher.any_instance.stubs(:match!)
      .raises(provider_error(:server_error))
      .then.returns(matcher_result(:linked))

    scan = create_scan
    PaperlessSweepDocumentsJob.perform_now(scan.id)
    scan.reload

    assert_equal "completed", scan.status
    assert_equal 1, scan.error_count
    assert_equal 1, scan.linked_count
    assert_equal 2, scan.processed_count
  end

  test "aborts the whole sweep on an unauthorized provider error" do
    stub_search([ document(1), document(2) ])
    PaperlessConnection::DocumentMatcher.any_instance.stubs(:match!).raises(provider_error(:unauthorized))

    scan = create_scan
    PaperlessSweepDocumentsJob.perform_now(scan.id)
    scan.reload

    assert_equal "failed", scan.status
    assert_equal 1, scan.error_count
    assert_equal 0, scan.processed_count
  end

  test "does nothing for a scan that is no longer pending" do
    PaperlessConnection::DocumentMatcher.any_instance.expects(:match!).never

    scan = create_scan
    scan.update!(status: "completed")

    PaperlessSweepDocumentsJob.perform_now(scan.id)
  end

  test "passes the scan's added_from through to the search" do
    Provider::Paperless.any_instance.expects(:search_documents)
      .with(has_entries(added_from: Date.new(2026, 9, 1)))
      .returns({ "count" => 0, "results" => [] })

    scan = create_scan(added_from: Date.new(2026, 9, 1))
    PaperlessSweepDocumentsJob.perform_now(scan.id)

    assert_equal "completed", scan.reload.status
  end

  private
    def create_scan(added_from: nil)
      PaperlessScan.create!(family: @family, paperless_connection: @connection, trigger: "manual", mode: "documents", added_from: added_from)
    end

    def create_transaction
      transaction = Transaction.new
      accounts(:depository).entries.create!(name: "Some Shop", date: Date.current, amount: 42.42, currency: "USD", entryable: transaction)
      transaction
    end

    def document(id)
      { "id" => id, "title" => "Document #{id}", "content" => "", "created" => Date.current.iso8601, "correspondent" => nil, "custom_fields" => [] }
    end

    def stub_search(documents)
      Provider::Paperless.any_instance.stubs(:search_documents).returns({ "count" => documents.size, "results" => documents })
    end

    def matcher_result(outcome)
      PaperlessConnection::DocumentMatcher::Result.new(outcome: outcome, candidates: [])
    end

    def stub_matcher_outcomes(*outcomes)
      stub = PaperlessConnection::DocumentMatcher.any_instance.stubs(:match!)
      outcomes.each_with_index do |outcome, index|
        stub = stub.then if index.positive?
        stub = stub.returns(matcher_result(outcome))
      end
    end

    def provider_error(error_type)
      Provider::Paperless::Error.new("paperless boom", error_type)
    end

    def with_max_documents(limit)
      original = PaperlessSweepDocumentsJob::MAX_DOCUMENTS_PER_RUN
      silence_warnings { PaperlessSweepDocumentsJob.const_set(:MAX_DOCUMENTS_PER_RUN, limit) }
      yield
    ensure
      silence_warnings { PaperlessSweepDocumentsJob.const_set(:MAX_DOCUMENTS_PER_RUN, original) }
    end
end
