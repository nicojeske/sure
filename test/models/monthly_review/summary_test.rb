require "test_helper"

class MonthlyReview::SummaryTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @skipped = review_transaction("Skipped", day: 2)
    @reviewed = review_transaction("Reviewed", day: 3)
    @open = review_transaction("Open", day: 4)
    @later = review_transaction("Later", day: 5)
    @reviewed.mark_reviewed!(@user)
  end

  test "an unreviewed entry before the last reviewed one was skipped, later ones are open" do
    assert_equal 4, summary.total
    assert_equal 1, summary.reviewed_count
    assert_equal 1, summary.skipped_count
    assert_equal 2, summary.open_count
    assert_equal %w[skipped reviewed pending pending], summary.list.map { |entry| summary.status(entry) }
    assert_equal [ @skipped, @open, @later ], summary.unreviewed_entries
  end

  test "nothing reviewed yet means everything is open" do
    @reviewed.unmark_reviewed!

    assert_equal 0, summary.skipped_count
    assert_equal 4, summary.open_count
  end

  test "once completed every unreviewed entry counts as skipped" do
    @review.complete!

    assert_equal 3, summary.skipped_count
    assert_equal 0, summary.open_count
  end

  test "income and expense come from the income statement for the review period" do
    review_transaction("Salary", day: 6, amount: -1000)
    review_transaction("Next month", day: 6, amount: 50).update!(date: Date.new(2026, 11, 2))

    assert_equal Money.new(1000, @family.currency), summary.income
    assert_equal Money.new(80, @family.currency), summary.expense
    assert_equal Money.new(920, @family.currency), summary.net
  end

  private
    def summary
      MonthlyReview::Summary.new(@review, @family.entries, user: @user)
    end
end
