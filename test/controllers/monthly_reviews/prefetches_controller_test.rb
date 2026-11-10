require "test_helper"

class MonthlyReviews::PrefetchesControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper
  include ActiveJob::TestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @entry = review_transaction("Edeka")
  end

  test "refresh forces a prefetch that retries failed suggestions" do
    @review.update_columns(prefetched_at: 1.minute.ago)

    assert_enqueued_with(job: MonthlyReview::PrefetchSuggestionsJob, args: [ @review, @user, { include_transfers: false, force: true } ]) do
      post monthly_review_prefetch_url(@review), headers: { "Referer" => monthly_review_card_url(@review, entry_id: @entry.id) }
    end

    assert_redirected_to monthly_review_card_url(@review, entry_id: @entry.id)
  end
end
