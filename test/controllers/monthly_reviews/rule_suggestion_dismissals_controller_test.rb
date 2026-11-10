require "test_helper"

class MonthlyReviews::RuleSuggestionDismissalsControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @entry = review_transaction("EON ABSCHLAG")
  end

  test "dismisses the pattern for the family and returns to the card" do
    assert_difference -> { @family.rule_suggestion_dismissals.count }, 1 do
      post monthly_review_rule_suggestion_dismissals_url(@review), params: { entry_id: @entry.id, pattern_key: "name:eon abschlag" }
    end

    dismissal = @family.rule_suggestion_dismissals.sole
    assert_equal "name:eon abschlag", dismissal.pattern_key
    assert_equal @user, dismissal.user
    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id)
  end

  test "dismissing a pattern twice keeps one row" do
    2.times do
      post monthly_review_rule_suggestion_dismissals_url(@review), params: { entry_id: @entry.id, pattern_key: "merchant:abc" }
    end

    assert_equal 1, @family.rule_suggestion_dismissals.count
    assert_response :redirect
  end

  test "a malformed pattern key is rejected" do
    assert_no_difference "RuleSuggestionDismissal.count" do
      post monthly_review_rule_suggestion_dismissals_url(@review), params: { entry_id: @entry.id, pattern_key: "bogus" }
    end

    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id)
  end

  test "an entry the user may not annotate 404s" do
    other = create_transaction(account: accounts(:credit_card), date: Date.new(2026, 10, 5))
    sign_in users(:family_member)
    users(:family_member).update!(preferences: { "preview_features_enabled" => true })

    assert_no_difference "RuleSuggestionDismissal.count" do
      post monthly_review_rule_suggestion_dismissals_url(@review), params: { entry_id: other.id, pattern_key: "name:gift" }
    end

    assert_response :not_found
  end
end
