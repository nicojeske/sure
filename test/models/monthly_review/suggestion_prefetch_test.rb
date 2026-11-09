require "test_helper"

class MonthlyReview::SuggestionPrefetchTest < ActiveSupport::TestCase
  include EntriesTestHelper
  include SqlQueryCapture

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }
    @connection = paperless_connections(:one)
    @review = MonthlyReview.for(@family, Date.new(2026, 10, 15))
    @provider = mock("llm")
    Provider::Registry.stubs(:preferred_llm_provider).returns(@provider)
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "Total 20.00" })
  end

  test "suggests from receipts of unreviewed queue entries only" do
    with_receipt = entry_with_receipt("Linked", document_id: 1)
    entry_with_receipt("Reviewed", document_id: 2).mark_reviewed!(@user)
    entry_with_receipt("Last month", document_id: 3, date: Date.new(2026, 9, 30))
    create_transaction(account: @account, date: Date.new(2026, 10, 4), name: "No receipt")
    expect_llm_calls(1)

    yielded = []
    suggestions = prefetch.run { |entry, suggestion| yielded << [ entry, suggestion ] }

    assert_equal [ with_receipt ], suggestions.map(&:entry)
    assert suggestions.all?(&:ready?)
    assert_equal [ [ with_receipt, suggestions.first ] ], yielded
  end

  test "uses a clear-cut suggested receipt but not close candidates" do
    clear = entry_with_receipt("Clear", document_id: 1, status: "suggested", score: 0.9)
    close = entry_with_receipt("Close", document_id: 2, status: "suggested", score: 0.8)
    close.transaction.receipt_links.create!(paperless_connection: @connection, document_id: 3, status: "suggested", score: 0.75)
    expect_llm_calls(1)

    assert_equal [ clear ], prefetch.run.map(&:entry)
  end

  test "skips entries that already have a suggestion for the same receipt" do
    entry_with_receipt("Linked", document_id: 1)
    expect_llm_calls(1)

    assert_equal 1, prefetch.run.size
    assert_empty prefetch.run
  end

  test "does not retry a failed or in-flight suggestion" do
    failed = entry_with_receipt("Failed", document_id: 1)
    pending = entry_with_receipt("Pending", document_id: 2)
    existing_suggestion(failed, failed.transaction.receipt_links.first, status: "failed")
    existing_suggestion(pending, pending.transaction.receipt_links.first, status: "pending")
    @provider.expects(:suggest_transaction_annotation).never

    assert_empty prefetch.run
  end

  test "reclaims a pending suggestion whose run died" do
    entry = entry_with_receipt("Stale", document_id: 1)
    stale = existing_suggestion(entry, entry.transaction.receipt_links.first, status: "pending")
    stale.update_columns(updated_at: (TransactionAnnotationSuggestion::PENDING_STALE_AFTER + 1.minute).ago)
    expect_llm_calls(1)

    assert_equal [ stale ], prefetch.run
    assert stale.reload.ready?
  end

  test "retries failed suggestions only when forced" do
    entry = entry_with_receipt("Failed", document_id: 1)
    failed = existing_suggestion(entry, entry.transaction.receipt_links.first, status: "failed")
    expect_llm_calls(1)

    assert_empty prefetch.run
    assert_equal [ failed ], prefetch(retry_failed: true).run
    assert failed.reload.ready?
  end

  test "a receipt failure fails only its entry and does not trip the breaker" do
    entries = 5.times.map { |i| entry_with_receipt("Entry #{i}", document_id: i + 1, date: Date.new(2026, 10, i + 1)) }
    Provider::Paperless.any_instance.stubs(:document).raises(Provider::Paperless::Error.new("gone", :not_found))
    Provider::Paperless.any_instance.stubs(:document).with(5).returns({ "content" => "Total 20.00" })
    expect_llm_calls(1)

    suggestions = prefetch.run

    assert_equal entries, suggestions.map(&:entry)
    assert_equal %w[failed failed failed failed ready], suggestions.map(&:status)
  end

  test "stops at the limit" do
    3.times { |i| entry_with_receipt("Entry #{i}", document_id: i + 1, date: Date.new(2026, 10, i + 1)) }
    expect_llm_calls(2)

    assert_equal 2, prefetch(limit: 2).run.size
  end

  test "stops after repeated provider failures" do
    5.times { |i| entry_with_receipt("Entry #{i}", document_id: i + 1, date: Date.new(2026, 10, i + 1)) }
    @provider.expects(:suggest_transaction_annotation).times(MonthlyReview::SuggestionPrefetch::MAX_CONSECUTIVE_FAILURES)
      .returns(Provider::Response.new(success?: false, data: nil, error: StandardError.new("down")))

    suggestions = nil
    assert_difference -> { DebugLogEntry.where(source: "MonthlyReview::SuggestionPrefetch").count }, 1 do
      suggestions = prefetch.run
    end

    assert_equal MonthlyReview::SuggestionPrefetch::MAX_CONSECUTIVE_FAILURES, suggestions.size
    assert suggestions.all?(&:failed?)
    log = DebugLogEntry.where(source: "MonthlyReview::SuggestionPrefetch").last
    assert_equal Transaction::AnnotationSuggester.new(@family, user: @user).llm_provider_key, log.provider_key
    assert_equal @review.id, log.metadata["monthly_review_id"]
    assert_equal MonthlyReview::SuggestionPrefetch::MAX_CONSECUTIVE_FAILURES, log.metadata["consecutive_failures"]
  end

  test "query count does not grow with the number of finished entries" do
    expect_llm_calls(0)
    queries_for_finished_entries(1) # warm up one-off lookups
    one = queries_for_finished_entries(1)
    three = queries_for_finished_entries(3)

    assert_equal one, three
  end

  test "does nothing without an LLM provider or Paperless connection" do
    entry_with_receipt("Linked", document_id: 1)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)
    assert_empty prefetch.run

    Provider::Registry.stubs(:preferred_llm_provider).returns(@provider)
    @connection.destroy
    @family.reload
    @provider.expects(:suggest_transaction_annotation).never
    assert_empty prefetch.run
  end

  test "covers only entries the user may annotate" do
    member = users(:family_member)
    entry_with_receipt("Read only for member", document_id: 1, account: accounts(:credit_card))
    @provider.expects(:suggest_transaction_annotation).never

    assert_empty MonthlyReview::SuggestionPrefetch.new(@review, user: member).run
  end

  private
    def queries_for_finished_entries(count)
      @family.accounts.each { |account| account.entries.delete_all }
      count.times do |i|
        entry = entry_with_receipt("Done #{i}", document_id: i + 1, date: Date.new(2026, 10, i + 1))
        entry.transaction.receipt_links.create!(paperless_connection: @connection, document_id: i + 100, status: "suggested", score: 0.2)
        existing_suggestion(entry, entry.transaction.receipt_links.linked.first, status: "ready")
      end

      capture_sql_queries { prefetch.run }.size
    end

    def prefetch(**options)
      MonthlyReview::SuggestionPrefetch.new(@review, user: @user, **options)
    end

    def entry_with_receipt(name, document_id:, status: "linked", score: 0.9, date: Date.new(2026, 10, 5), account: @account)
      entry = create_transaction(account: account, date: date, name: name, amount: 20)
      entry.transaction.receipt_links.create!(paperless_connection: @connection, document_id: document_id, status: status, score: score)
      entry
    end

    def existing_suggestion(entry, link, status:)
      TransactionAnnotationSuggestion.create!(
        entry: entry, family: @family, source: "receipt", status: status, receipt_link: link,
        input_hash: Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: link)
      )
    end

    def expect_llm_calls(count)
      result = Provider::LlmConcept::TransactionAnnotation.new(
        name: "Coffee", merchant_name: nil, category_name: nil, tag_names: [], notes: nil,
        receipt_total: nil, split: nil, confidence: 0.8, rationale: nil
      )
      @provider.expects(:suggest_transaction_annotation).times(count).returns(Provider::Response.new(success?: true, data: result, error: nil))
    end
end
