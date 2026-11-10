require "test_helper"

class MonthlyReview::ReadReceiptJobTest < ActiveJob::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @entry = review_transaction("EDEKA SAGT DANKE")
    @link = link_receipt(@entry, document_id: 7)
    @suggestion = ready_suggestion(@entry, receipt_link: @link, status: "pending")
  end

  test "reads the claimed receipt and refreshes the card" do
    Provider::Paperless.any_instance.stubs(:document).with(7).returns({ "content" => "EDEKA 20,00" })
    stub_llm(name: "Groceries")
    Turbo::StreamsChannel.expects(:broadcast_refresh_to).with(@family, :monthly_review, @entry)

    MonthlyReview::ReadReceiptJob.perform_now(@suggestion, @user)

    assert @suggestion.reload.ready?
    assert_equal "Groceries", @suggestion.payload["name"]
  end

  test "does nothing once the suggestion is no longer pending" do
    @suggestion.update!(status: "ready")
    forbid_llm
    Turbo::StreamsChannel.expects(:broadcast_refresh_to).never

    MonthlyReview::ReadReceiptJob.perform_now(@suggestion, @user)
  end

  test "ignores a user from another family" do
    forbid_llm

    MonthlyReview::ReadReceiptJob.perform_now(@suggestion, users(:empty))

    assert @suggestion.reload.pending?
  end
end
