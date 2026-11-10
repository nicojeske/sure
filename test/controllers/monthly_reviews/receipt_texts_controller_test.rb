require "test_helper"

class MonthlyReviews::ReceiptTextsControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @entry = review_transaction("Edeka")
    @link = link_receipt(@entry, document_id: 9)
  end

  test "shows the receipt's OCR text" do
    Provider::Paperless.any_instance.stubs(:document).with(9).returns({ "content" => "EDEKA Markt\nSUMME 20,00" })

    get monthly_review_receipt_text_url(@review), params: { entry_id: @entry.id, receipt_link_id: @link.id, variant: "wide" }

    assert_response :success
    assert_select "turbo-frame#receipt_text_wide_#{@link.id}"
    assert_match "SUMME 20,00", response.body
  end

  test "shows a notice when Paperless cannot be reached" do
    Provider::Paperless.any_instance.stubs(:document).raises(Provider::Paperless::Error.new("down", :unreachable))

    get monthly_review_receipt_text_url(@review), params: { entry_id: @entry.id, receipt_link_id: @link.id, variant: "wide" }

    assert_response :success
    assert_select "[data-review-receipt-error]"
  end

  test "only reads receipts of the entry" do
    other = review_transaction("Other", day: 6)

    get monthly_review_receipt_text_url(@review), params: { entry_id: other.id, receipt_link_id: @link.id }

    assert_response :not_found
  end
end
