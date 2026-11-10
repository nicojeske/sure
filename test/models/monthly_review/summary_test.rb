require "test_helper"

class MonthlyReview::SummaryTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @passed = review_transaction("Passed over", day: 2)
    @reviewed = review_transaction("Reviewed", day: 3)
    @later = review_transaction("Later", day: 4)
    @reviewed.mark_reviewed!(@user)
  end

  test "counts reviewed and open transactions and lists the open ones in queue order" do
    assert_equal 3, summary.total
    assert_equal 1, summary.reviewed_count
    assert_equal 2, summary.open_count
    assert_equal [ @passed, @later ], summary.open_entries
  end

  test "completing the month keeps unreviewed transactions open" do
    @review.complete!

    assert_equal 2, summary.open_count
  end

  test "income and expense come from the income statement for the review period" do
    review_transaction("Salary", day: 6, amount: -1000)
    review_transaction("Next month", day: 6, amount: 50).update!(date: Date.new(2026, 11, 2))

    assert_equal Money.new(1000, @family.currency), summary.income
    assert_equal Money.new(60, @family.currency), summary.expense
    assert_equal Money.new(940, @family.currency), summary.net
  end

  private
    def summary
      MonthlyReview::Summary.new(@review, @family.entries, user: @user)
    end
end
