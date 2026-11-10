require "test_helper"

class Assistant::Function::GetMonthlyReviewTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @function = Assistant::Function::GetMonthlyReview.new(@user)
    @first = review_transaction("Coffee shop", day: 3)
    @second = review_transaction("Book store", day: 4)
    @third = review_transaction("Bakery", day: 6)
  end

  test "returns progress, totals, the note and the open transactions in review order" do
    @second.mark_reviewed!(@user)
    salary = review_transaction("Salary", day: 7, amount: -1000)
    link_receipt(@third, document_id: 7)
    @review.update!(notes: "Quiet month")

    result = @function.call("month" => "2026-10")

    assert_equal "oct-2026", result[:month]
    assert_equal "in_progress", result[:status]
    assert_equal "Quiet month", result[:notes]
    assert_equal({ total: 4, reviewed: 1, open: 3 }, result[:progress])
    assert_equal "$1,000.00", result[:income]
    assert_equal "$60.00", result[:expense]
    assert_equal [ @first, @third, salary ].map(&:entryable_id), result[:open_transactions].pluck(:id)

    third = result[:open_transactions].second
    assert_equal "Bakery", third[:name]
    assert_equal "$20.00", third[:amount]
    assert_equal "expense", third[:classification]
    assert third[:receipt]
    assert_nil result[:open_transactions].first[:receipt]
    assert_equal "income", result[:open_transactions].last[:classification]
    assert_nil result[:open_transactions_truncated]
  end

  test "reading a month that was never opened stores nothing" do
    @review.destroy!

    assert_no_difference "MonthlyReview.count" do
      result = @function.call("month" => "oct-2026")
      assert_equal "not_started", result[:status]
      assert_equal 3, result[:progress][:open]
    end
  end

  test "leaves transfers out unless asked" do
    transfer = review_transaction("To savings", day: 8, kind: "funds_movement")

    assert_not_includes @function.call("month" => "2026-10")[:open_transactions].pluck(:id), transfer.entryable_id
    assert_includes @function.call("month" => "2026-10", "include_transfers" => true)[:open_transactions].pluck(:id), transfer.entryable_id
  end

  test "a member with only read-only access sees no transactions to review" do
    viewer = users(:family_member)
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    result = Assistant::Function::GetMonthlyReview.new(viewer).call("month" => "2026-10")

    assert_equal({ total: 0, reviewed: 0, open: 0 }, result[:progress])
    assert_empty result[:open_transactions]
  end

  test "another family's review shows none of these transactions" do
    result = Assistant::Function::GetMonthlyReview.new(users(:empty)).call("month" => "2026-10")

    assert_empty result[:open_transactions]
    assert_equal 0, result[:progress][:total]
  end

  test "refuses months outside the budget range and malformed months" do
    assert_no_difference "MonthlyReview.count" do
      assert_equal "invalid_month", @function.call("month" => "1900-01")[:error]
      assert_equal "invalid_month", @function.call("month" => "October")[:error]
    end
  end
end
