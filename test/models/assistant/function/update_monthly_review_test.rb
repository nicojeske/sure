require "test_helper"

class Assistant::Function::UpdateMonthlyReviewTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @function = Assistant::Function::UpdateMonthlyReview.new(@user)
    @entry = review_transaction("Coffee shop", day: 3)
  end

  test "saves the note and keeps the month open" do
    result = @function.call("month" => "oct-2026", "notes" => "Car insurance went up")

    assert result[:success]
    assert_equal "Car insurance went up", @review.reload.notes
    assert_equal "not_started", result[:status]
    assert_not @review.completed?
  end

  test "completes with open transactions, then reopens and clears the note" do
    result = @function.call("month" => "2026-10", "notes" => "All fine", "completion" => "complete")

    assert_equal "completed", result[:status]
    assert_equal({ total: 1, reviewed: 0, open: 1 }, result[:progress])
    assert @review.reload.completed?

    result = @function.call("month" => "2026-10", "completion" => "reopen", "notes" => nil)

    assert_equal "not_started", result[:status]
    assert_not @review.reload.completed?
    assert_nil @review.notes
  end

  test "reports progress with transfers only when asked" do
    review_transaction("To savings", day: 8, kind: "funds_movement")

    assert_equal 1, @function.call("month" => "2026-10", "notes" => "x")[:progress][:total]
    assert_equal 2, @function.call("month" => "2026-10", "notes" => "x", "include_transfers" => true)[:progress][:total]
  end

  test "creates the review of a month that was never opened" do
    @review.destroy!

    assert_difference "MonthlyReview.count", 1 do
      @function.call("month" => "oct-2026", "notes" => "First note")
    end
    assert_equal "First note", MonthlyReview.for(@family, @review.start_date).notes
  end

  test "refuses months outside the budget range without creating a review" do
    assert_no_difference "MonthlyReview.count" do
      assert_equal "invalid_month", @function.call("month" => "1900-01", "notes" => "Too old")[:error]
      assert_equal "invalid_month", @function.call("month" => "someday", "notes" => "Never")[:error]
      assert_equal "invalid_month", @function.call("notes" => "Which month?")[:error]
    end
  end

  test "refuses an unknown completion and a call without changes" do
    assert_equal "invalid_arguments", @function.call("month" => "2026-10", "completion" => "finish")[:error]
    assert_equal "no_changes", @function.call("month" => "2026-10")[:error]
    assert_not @review.reload.completed?
  end

  test "guests and members with only read-only shares can't change the review" do
    account_shares(:depository_shared_with_member).update!(permission: "read_only")
    result = Assistant::Function::UpdateMonthlyReview.new(users(:family_member)).call("month" => "2026-10", "completion" => "complete")
    assert_equal "not_authorized", result[:error]

    @user.update!(role: :guest)
    result = Assistant::Function::UpdateMonthlyReview.new(@user).call("month" => "2026-10", "notes" => "Guest note")
    assert_equal "not_authorized", result[:error]

    assert_nil @review.reload.notes
    assert_not @review.completed?
  end
end
