require "test_helper"

class MonthlyReview::CardTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @entry = review_transaction("EDEKA SAGT DANKE")
    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)
  end

  test "always has the five field rows in order, unchanged without a proposal" do
    card = card_for(@entry)

    assert_equal :empty, card.state
    assert_equal %w[name merchant category tags notes], card.fields.map(&:key)
    assert_equal [ 1, 2, 3, 4, 5 ], card.fields.map(&:number)
    assert card.fields.all? { |field| field.status == :unchanged }
  end

  test "a linked receipt without a suggestion is unread, queued while a prefetch runs" do
    link_receipt(@entry, document_id: 1)

    card = card_for(@entry)
    assert_equal :unread, card.state
    assert_not card.queued?

    @review.update_columns(prefetched_at: 1.minute.ago)
    assert card_for(@entry).queued?
  end

  test "close suggested receipts ask for a choice" do
    first = link_receipt(@entry, document_id: 1, status: "suggested", score: 0.7)
    second = link_receipt(@entry, document_id: 2, status: "suggested", score: 0.65)

    card = card_for(@entry)

    assert_equal :receipt_choice, card.state
    assert_equal [ first, second ], card.receipt_candidates
  end

  test "a picked candidate's proposal is shown" do
    link_receipt(@entry, document_id: 1, status: "suggested", score: 0.7)
    picked = link_receipt(@entry, document_id: 2, status: "suggested", score: 0.65)
    ready_suggestion(@entry, receipt_link: picked, name: "Groceries")

    card = card_for(@entry)

    assert_equal :proposal, card.state
    assert_equal picked, card.receipt_link
  end

  test "a hint proposal wins over the receipt proposal unless the URL names one" do
    link = link_receipt(@entry, document_id: 1)
    receipt = ready_suggestion(@entry, receipt_link: link, name: "From receipt")
    hint = ready_suggestion(@entry, source: "hint", receipt_link: link, hint: "milk", name: "From hint")

    assert_equal hint, card_for(@entry).suggestion
    assert_equal receipt, card_for(@entry, suggestion_id: receipt.id).suggestion
  end

  test "a proposed change is selectable and the others stay unchanged" do
    link = link_receipt(@entry, document_id: 1)
    ready_suggestion(@entry, receipt_link: link, name: "Groceries", new_merchant_name: "Edeka")

    fields = card_for(@entry).fields.index_by(&:key)

    assert fields["name"].change?
    assert fields["name"].checked
    assert_equal "Groceries", fields["name"].proposed
    assert_equal "Edeka", fields["merchant"].proposed.name
    assert_equal :unchanged, fields["category"].status
  end

  test "without a receipt or hint the learned category is proposed" do
    category = categories(:food_and_drink)
    Family::BayesCategorizer.any_instance.stubs(:classify).returns([ category.id, 0.9 ])

    card = card_for(@entry)

    assert_equal :proposal, card.state
    assert card.learned?
    assert card.fields.index_by(&:key)["category"].change?
  end

  test "a reviewed card shows what the accepted proposal applied" do
    link = link_receipt(@entry, document_id: 1)
    suggestion = ready_suggestion(@entry, receipt_link: link, name: "Groceries")
    suggestion.apply!(user: @user, fields: %w[name])

    card = card_for(@entry.reload)

    assert_equal :reviewed, card.state
    assert_equal suggestion, card.suggestion
    assert_equal 1, card.applied_change_count
    assert_equal :applied, card.fields.first.status
  end

  test "a proposed merchant or split category from another family is not shown" do
    foreign_merchant = FamilyMerchant.create!(family: families(:empty), name: "Elsewhere")
    foreign_category = families(:empty).categories.create!(name: "Foreign")
    own_category = categories(:food_and_drink)
    suggestion = ready_suggestion(@entry, source: "hint", hint: "two things", merchant_id: foreign_merchant.id, split: [
      { "name" => "One", "amount" => "12.0", "category_id" => own_category.id, "tag_ids" => [] },
      { "name" => "Two", "amount" => "8.0", "category_id" => foreign_category.id, "tag_ids" => [] }
    ])

    card = card_for(@entry, suggestion_id: suggestion.id)

    assert_nil card.fields.index_by(&:key)["merchant"].proposed
    assert_equal [ own_category, nil ], card.split_parts.map(&:category)
  end

  private
    def card_for(entry, suggestion_id: nil)
      MonthlyReview::Card.new(@review, entry, user: @user, suggestion_id: suggestion_id)
    end
end
