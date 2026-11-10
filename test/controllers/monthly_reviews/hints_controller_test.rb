require "test_helper"

class MonthlyReviews::HintsControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @entry = review_transaction("AMAZON MKTPLACE")
  end

  test "a hint builds a proposal and shows it on the card" do
    stub_llm(name: "Apfelentkerner + Handwärmer")

    post monthly_review_hints_url(@review), params: { entry_id: @entry.id, hint: "Apfelentkerner + Handwärmer" }

    suggestion = @entry.annotation_suggestions.sole
    assert suggestion.hint?
    assert suggestion.ready?
    assert_equal "Apfelentkerner + Handwärmer", suggestion.hint_text
    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id, suggestion_id: suggestion.id)
  end

  test "a blank hint does not call the LLM" do
    forbid_llm

    post monthly_review_hints_url(@review), params: { entry_id: @entry.id, hint: "  " }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id)
    assert_empty @entry.annotation_suggestions
  end

  test "a hint for an entry the user may not annotate 404s" do
    other = create_transaction(account: accounts(:credit_card), date: Date.new(2026, 10, 5))
    sign_in users(:family_member)
    users(:family_member).update!(preferences: { "preview_features_enabled" => true })
    forbid_llm

    post monthly_review_hints_url(@review), params: { entry_id: other.id, hint: "Gift" }

    assert_response :not_found
  end
end
