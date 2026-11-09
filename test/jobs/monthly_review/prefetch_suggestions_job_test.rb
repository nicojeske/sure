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

  test "ignores a user from another family" do
    MonthlyReview::SuggestionPrefetch.any_instance.expects(:run).never

    MonthlyReview::PrefetchSuggestionsJob.perform_now(@review, users(:empty))
  end
end
