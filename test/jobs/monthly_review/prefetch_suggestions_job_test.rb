require "test_helper"

class MonthlyReview::PrefetchSuggestionsJobTest < ActiveJob::TestCase
  setup do
    @user = users(:family_admin)
    @review = MonthlyReview.for(@user.family, Date.new(2026, 10, 15))
  end

  test "broadcasts a refresh to each prefetched entry's card stream" do
    entry = entries(:transaction)
    suggestion = TransactionAnnotationSuggestion.new
    MonthlyReview::SuggestionPrefetch.any_instance.expects(:run).yields(entry, suggestion).returns([ suggestion ])
    Turbo::StreamsChannel.expects(:broadcast_refresh_to).with(@user.family, :monthly_review, entry)

    MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, @user, include_transfers: true)
  end

  test "a forced run retries suggestions that failed before it started" do
    started_at = 1.minute.ago
    MonthlyReview::SuggestionPrefetch.expects(:new)
      .with(@review, user: @user, include_transfers: false, retry_failed: started_at, limit: MonthlyReview::PrefetchSuggestionsJob::BATCH_SIZE)
      .returns(stub(run: []))

    MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, @user, force: true, started_at: started_at)
  end

  test "a full batch queues the next one with what is left of the limit" do
    batch = MonthlyReview::PrefetchSuggestionsJob::BATCH_SIZE
    MonthlyReview::SuggestionPrefetch.any_instance.expects(:run).returns(Array.new(batch) { TransactionAnnotationSuggestion.new })

    assert_enqueued_with(job: MonthlyReview::PrefetchSuggestionsJob, args: ->(args) { args.last[:remaining] == 15 - batch }) do
      MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, @user, remaining: 15)
    end
  end

  test "a short batch ends the run" do
    MonthlyReview::SuggestionPrefetch.any_instance.expects(:run).returns([ TransactionAnnotationSuggestion.new ])

    assert_no_enqueued_jobs(only: MonthlyReview::PrefetchSuggestionsJob) do
      MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, @user)
    end
  end

  test "ignores a user from another family" do
    MonthlyReview::SuggestionPrefetch.any_instance.expects(:run).never

    MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, users(:empty))
  end
end
