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

  test "rows a rule handled are found for the whole list at once" do
    tag = @family.tags.create!(name: "Groceries")
    rule = @family.rules.create!(
      name: "First", resource_type: "transaction", active: true,
      conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "First") ],
      actions: [
        Rule::Action.new(action_type: "set_transaction_category", value: categories(:food_and_drink).id),
        Rule::Action.new(action_type: "set_transaction_tags", value: [ tag.id ])
      ]
    )
    Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run

    list = @review.card_list(@family.entries)
    list.to_a

    # Enrichments, taggings and rules: one query each, however many rows.
    handled = assert_queries_count(3) { list.map { |entry| list.rule_handled?(entry) } }
    assert_equal [ true, false, false ], handled
    assert_equal rule, list.rule_provenance.rule_set_fields(@first)["category"]
  end
end
