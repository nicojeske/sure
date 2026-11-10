require "test_helper"

class MonthlyReview::CardListTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @first = review_transaction("First", day: 2)
    @second = review_transaction("Second", day: 3)
    @third = review_transaction("Third", day: 4)
    @second.mark_reviewed!(@user)
  end

  test "a row is the current card, reviewed or open; passing over an entry leaves it open" do
    list = @review.card_list(@family.entries)

    assert_equal %w[open reviewed current], list.map { |entry| list.status(entry, @third) }
    assert_equal %w[open reviewed open], list.map { |entry| list.status(entry, nil) }
  end
end
