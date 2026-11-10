require "test_helper"

class MonthlyReviews::ReceiptSearchesControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @entry = review_transaction("Edeka", amount: 23.45)
    Provider::Paperless.any_instance.stubs(:correspondents).returns({ 3 => "Edeka Markt" })
  end

  test "index searches Paperless around the transaction date" do
    Provider::Paperless.any_instance.expects(:search_documents)
      .with(has_entries(query: "Edeka", created_from: Date.new(2026, 9, 28), created_to: Date.new(2026, 10, 12)))
      .returns({ "results" => [ { "id" => 42, "title" => "Kassenbon Edeka", "correspondent" => 3, "created" => "2026-10-05" } ], "next" => nil })

    get monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, q: "Edeka" }

    assert_response :success
    assert_select "[data-review-search-result]", 1
    assert_match "Kassenbon Edeka", response.body
  end

  test "index shows an error when Paperless is unreachable" do
    Provider::Paperless.any_instance.stubs(:search_documents).raises(Provider::Paperless::Error.new("down", :unreachable))

    get monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, q: "Edeka" }

    assert_response :success
    assert_select "[data-review-search-error]"
  end

  test "picking a document links it and reads it right away" do
    Provider::Paperless.any_instance.stubs(:document).with("42").returns({ "id" => 42, "title" => "Kassenbon Edeka", "correspondent" => 3, "created" => "2026-10-05" })
    Provider::Paperless.any_instance.stubs(:document).with(42).returns({ "id" => 42, "content" => "Edeka 23,45" })
    stub_llm(name: "Groceries")

    post monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, document_id: "42" }

    link = @entry.transaction.receipt_links.sole
    assert link.linked?
    assert_equal 42, link.document_id
    suggestion = @entry.annotation_suggestions.sole
    assert_equal link, suggestion.receipt_link
    assert suggestion.ready?
    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id, suggestion_id: suggestion.id)
  end

  test "picking a document whose read is already in flight does not call the LLM" do
    Provider::Paperless.any_instance.stubs(:document).with("42").returns({ "id" => 42, "title" => "Kassenbon Edeka", "correspondent" => 3, "created" => "2026-10-05" })
    link = link_receipt(@entry, document_id: 42)
    pending = ready_suggestion(@entry, receipt_link: link, status: "pending")
    forbid_llm

    post monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, document_id: "42" }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id, suggestion_id: pending.id)
    assert pending.reload.pending?
  end

  test "a Paperless failure while linking goes back to the card" do
    Provider::Paperless.any_instance.stubs(:document).raises(Provider::Paperless::Error.new("gone", :not_found))
    forbid_llm

    post monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, document_id: "42" }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @entry.id)
    assert_empty @entry.transaction.receipt_links
  end

  test "404s without a configured Paperless connection" do
    @connection.destroy!

    get monthly_review_receipt_searches_url(@review), params: { entry_id: @entry.id, q: "Edeka" }

    assert_response :not_found
  end
end
