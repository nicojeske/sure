require "test_helper"

class Receipts::LinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "confirm links a suggestion and re-renders the list" do
    link = receipt_links(:suggested_transfer_out)

    patch confirm_receipts_link_path(link, status: "suggested"), as: :turbo_stream

    assert_response :success
    assert_equal "linked", link.reload.status
    assert_match "receipts_list", response.body
  end

  test "confirm re-renders the list through the filters it was given" do
    link = receipt_links(:suggested_transfer_out)

    patch confirm_receipts_link_path(link, status: "suggested", source: "auto"), as: :turbo_stream

    assert_response :success
    # Now linked, so it must fall out of a suggested-only list.
    assert_not_includes rendered_links, link
  end

  test "dismiss marks a suggestion dismissed" do
    link = receipt_links(:suggested_transfer_out)

    patch dismiss_receipts_link_path(link, status: "suggested"), as: :turbo_stream

    assert_response :success
    assert_equal "dismissed", link.reload.status
  end

  test "confirm restores a dismissed match" do
    link = receipt_links(:dismissed_transfer_in)

    patch confirm_receipts_link_path(link, status: "dismissed"), as: :turbo_stream

    assert_response :success
    assert_equal "linked", link.reload.status
  end

  test "destroy removes the match" do
    link = receipt_links(:linked_one)

    assert_difference "ReceiptLink.count", -1 do
      delete receipts_link_path(link), as: :turbo_stream
    end

    assert_response :success
    assert_not ReceiptLink.exists?(link.id)
  end

  test "cannot act on a receipt link in another family" do
    other_connection = PaperlessConnection.create!(
      family: families(:empty),
      base_url: "https://other.example.com",
      api_token: "other-token"
    )
    foreign = ReceiptLink.create!(
      transaction_record: transactions(:one),
      paperless_connection: other_connection,
      document_id: 900,
      status: "suggested"
    )

    patch confirm_receipts_link_path(foreign), as: :turbo_stream

    assert_response :not_found
    assert_equal "suggested", foreign.reload.status
  end

  test "cannot act on a receipt link the user has no annotate permission for" do
    link = receipt_links(:suggested_transfer_out)
    link.transaction_record.entry.account.update!(owner: users(:family_member))

    patch confirm_receipts_link_path(link), as: :turbo_stream

    assert_response :not_found
    assert_equal "suggested", link.reload.status
  end

  test "returns not found when Paperless is not configured" do
    link = receipt_links(:suggested_transfer_out)
    @connection.update_column(:api_token, nil)

    patch confirm_receipts_link_path(link), as: :turbo_stream

    assert_response :not_found
    assert_equal "suggested", link.reload.status
  end

  private
    def rendered_links
      @controller.view_assigns["receipt_links"].to_a
    end
end
