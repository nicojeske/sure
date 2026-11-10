require "test_helper"

class MonthlyReviewsControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @first = review_transaction("Coffee shop", day: 3)
    @second = review_transaction("Book store", day: 4)
    @third = review_transaction("Bakery", day: 6)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get monthly_reviews_url
    assert_redirected_to root_path

    get monthly_review_url(@review)
    assert_redirected_to root_path
  end

  test "index lists the last twelve months with progress and a completed badge" do
    @first.mark_reviewed!(@user)
    MonthlyReview.for(@family, Date.new(2026, 9, 1)).complete!

    travel_to Date.new(2026, 11, 10) do
      get monthly_reviews_url
    end

    assert_response :success
    assert_select "[data-review-month]", 12
    assert_select "[data-review-month='oct-2026'][href=?]", monthly_review_path(@review), text: /1 of 3 reviewed/
    assert_select "[data-review-month='oct-2026']", text: /In progress/
    assert_select "[data-review-month='sep-2026']", text: /Completed/
    assert_select "[data-breadcrumbs] > span:last-child", text: I18n.t("breadcrumbs.monthly_reviews")
  end

  test "summary shows income, expense, review counts and the unreviewed transactions" do
    @second.mark_reviewed!(@user)
    review_transaction("Salary", day: 7, amount: -1000)

    get monthly_review_url(@review)

    assert_response :success
    assert_select "h1", text: "October 2026"
    assert_select "dd", text: "1 of 4"
    assert_select "[data-review-entry-id='#{@first.id}'][data-status='skipped']"
    assert_select "[data-review-entry-id='#{@third.id}'][data-status='pending']"
    assert_select "[data-review-entry-id='#{@second.id}']", count: 0
    assert_select "main", text: /\$1,000\.00/
    assert_select "main", text: /\$60\.00/
    assert_select "a[href=?]", monthly_review_card_path(@review), text: /Continue review \(3 left\)/
    assert_select "[data-breadcrumbs] a[href=?]", monthly_reviews_path, text: I18n.t("breadcrumbs.monthly_reviews")
    assert_select "[data-breadcrumbs] > span:last-child", text: "October 2026"
  end

  test "summary 404s for an unknown month" do
    get monthly_review_url("nonsense")

    assert_response :not_found
  end

  test "months outside the budget range 404 without creating a review" do
    assert_no_difference "MonthlyReview.count" do
      get monthly_review_url("jan-1900")
      assert_response :not_found

      get monthly_review_card_url("jan-1900")
      assert_response :not_found

      patch monthly_review_url("jan-1900"), params: { monthly_review: { notes: "Too old" } }
      assert_response :not_found
    end
  end

  test "opening a month's summary creates no review until something is saved" do
    @review.destroy!

    assert_no_difference "MonthlyReview.count" do
      get monthly_review_url(@review)
    end
    assert_response :success

    assert_difference "MonthlyReview.count", 1 do
      patch monthly_review_url(@review), params: { monthly_review: { notes: "First note" } }
    end
    assert_equal "First note", MonthlyReview.for(@family, @review.start_date).notes
  end

  test "saving the note keeps the month open" do
    patch monthly_review_url(@review), params: { monthly_review: { notes: "Car insurance went up" } }

    assert_redirected_to monthly_review_path(@review)
    assert_equal "Car insurance went up", @review.reload.notes
    assert_not @review.completed?
  end

  test "completing saves the note and completes the month, reopening undoes it" do
    patch monthly_review_url(@review, include_transfers: "1"), params: { monthly_review: { notes: "All fine" }, completion: "complete" }

    assert_redirected_to monthly_review_path(@review, include_transfers: "1")
    assert @review.reload.completed?
    assert_equal "All fine", @review.notes

    get monthly_review_url(@review)
    assert_select "button[name='completion'][value='reopen']"

    patch monthly_review_url(@review), params: { completion: "reopen" }

    assert_not @review.reload.completed?
    assert_equal "All fine", @review.notes
  end

  test "guests can't change the review" do
    @user.update!(role: :guest)

    patch monthly_review_url(@review), params: { monthly_review: { notes: "Guest note" }, completion: "complete" }

    assert_redirected_to accounts_path
    assert_nil @review.reload.notes
    assert_not @review.completed?
  end

  test "a member with only read-only shares can't change the review and sees no form" do
    viewer = users(:family_member)
    viewer.update!(preferences: (viewer.preferences || {}).merge("preview_features_enabled" => true))
    account_shares(:depository_shared_with_member).update!(permission: "read_only")
    sign_in viewer

    get monthly_review_url(@review)
    assert_response :success
    assert_select "form textarea[name='monthly_review[notes]']", count: 0

    patch monthly_review_url(@review), params: { monthly_review: { notes: "Viewer note" }, completion: "complete" }

    assert_redirected_to monthly_review_path(@review)
    assert_nil @review.reload.notes
    assert_not @review.completed?
  end
end
