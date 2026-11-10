require "application_system_test_case"

# From the last card to the month's summary, back to a skipped card, and
# completing the month with a note so the overview shows it as completed.
class MonthlyReviewSummaryTest < ApplicationSystemTestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @user.update!(show_ai_sidebar: false)

    @coffee = review_transaction("Coffee", day: 3)
    @plain = review_transaction("Unknown shop", day: 4)
    @bakery = review_transaction("Bakery", day: 6)
    @coffee.mark_reviewed!(@user)

    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)
    forbid_llm

    sign_in @user
  end

  test "finishing the queue leads to the summary, where the month is completed" do
    visit monthly_review_card_path(@review, entry_id: @bakery.id)
    assert_selector "[data-review-card-entry-id='#{@bakery.id}']"
    find("body").send_keys([ :control, :enter ])
    assert_current_path monthly_review_path(@review, focus: "note")
    assert_selector "h1", exact_text: "October 2026"
    assert_selector "[data-breadcrumbs]", text: "Monthly review"
    assert_selector "[data-review-entry-id='#{@plain.id}'][data-status='skipped']"

    # A skipped transaction opens its card.
    find("[data-review-entry-id='#{@plain.id}'] a").click
    assert_selector "[data-review-card-entry-id='#{@plain.id}']"
    assert_current_path monthly_review_card_path(@review, entry_id: @plain.id)

    visit monthly_review_path(@review, focus: "note")
    assert_equal "monthly_review[notes]", evaluate_script("document.activeElement.name")
    fill_in "monthly_review[notes]", with: "Bakery prices went up"
    click_on I18n.t("monthly_reviews.completion.complete")
    assert_text I18n.t("monthly_reviews.update.completed")
    assert @review.reload.completed?
    assert_equal "Bakery prices went up", @review.notes

    click_on I18n.t("breadcrumbs.monthly_reviews")
    assert_selector "[data-review-month='oct-2026']", text: I18n.t("monthly_reviews.status.completed")
  end
end
