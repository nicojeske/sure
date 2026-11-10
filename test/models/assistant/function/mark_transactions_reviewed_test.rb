require "test_helper"

class Assistant::Function::MarkTransactionsReviewedTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @function = Assistant::Function::MarkTransactionsReviewed.new(@user)
    @first = review_transaction("Coffee shop", day: 3)
    @second = review_transaction("Book store", day: 4)
  end

  test "marks the month's transactions reviewed and reports the rest" do
    reviewed = review_transaction("Bakery", day: 6)
    reviewed.mark_reviewed!(@user)
    reviewed_at = reviewed.reload.reviewed_at
    november = create_transaction(account: @account, date: Date.new(2026, 11, 2), name: "Next month")
    foreign_account = families(:empty).accounts.create!(name: "Foreign", currency: "USD", balance: 0, accountable: Depository.new, owner: users(:empty))
    foreign = create_transaction(account: foreign_account, date: Date.new(2026, 10, 5), name: "Elsewhere")
    ids = [ @first, reviewed, november, foreign ].map(&:entryable_id) + [ "not-a-uuid" ]

    result = @function.call("month" => "oct-2026", "transaction_ids" => ids)

    assert result[:success]
    assert_equal [ @first.entryable_id ], result[:marked_ids]
    assert_equal [ reviewed.entryable_id ], result[:already_reviewed_ids]
    assert_equal [ november.entryable_id, foreign.entryable_id, "not-a-uuid" ], result[:not_found_ids]
    assert_equal({ total: 3, reviewed: 2, open: 1 }, result[:progress])

    assert_equal @user, @first.reload.reviewed_by
    assert_equal reviewed_at, reviewed.reload.reviewed_at
    assert_not november.reload.reviewed?
    assert_not foreign.reload.reviewed?
    assert_not @second.reload.reviewed?
  end

  test "marks and counts transfers only when asked" do
    transfer = review_transaction("To savings", day: 8, kind: "funds_movement")

    result = @function.call("month" => "2026-10", "transaction_ids" => [ transfer.entryable_id ])
    assert_equal [ transfer.entryable_id ], result[:not_found_ids]
    assert_equal({ total: 2, reviewed: 0, open: 2 }, result[:progress])
    assert_not transfer.reload.reviewed?

    result = @function.call("month" => "2026-10", "transaction_ids" => [ transfer.entryable_id ], "include_transfers" => true)
    assert_equal [ transfer.entryable_id ], result[:marked_ids]
    assert_equal({ total: 3, reviewed: 1, open: 2 }, result[:progress])
    assert transfer.reload.reviewed?
  end

  test "a read-only share marks nothing" do
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    result = Assistant::Function::MarkTransactionsReviewed.new(users(:family_member))
      .call("month" => "2026-10", "transaction_ids" => [ @first.entryable_id ])

    assert_equal [ @first.entryable_id ], result[:not_found_ids]
    assert_not @first.reload.reviewed?
  end

  test "validates the month and the id list" do
    assert_equal "invalid_month", @function.call("transaction_ids" => [ @first.entryable_id ])[:error]
    assert_equal "invalid_month", @function.call("month" => "1900-01", "transaction_ids" => [ @first.entryable_id ])[:error]
    assert_equal "invalid_arguments", @function.call("month" => "2026-10", "transaction_ids" => [])[:error]
    assert_not @first.reload.reviewed?
  end
end
