require "test_helper"

class ReceiptLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    sign_in @user
  end

  test "index renders linked and suggested receipt links" do
    get transaction_receipt_links_path(entries(:transaction))

    assert_response :success
    assert_select "#" + ActionView::RecordIdentifier.dom_id(transactions(:one), :receipt_links)
  end

  test "confirm promotes a suggestion to linked" do
    receipt_link = receipt_links(:suggested_transfer_out)

    patch confirm_transaction_receipt_link_path(entries(:transfer_out), receipt_link)

    assert_response :success
    assert_equal "linked", receipt_link.reload.status
  end

  test "dismiss sets the status to dismissed" do
    receipt_link = receipt_links(:suggested_transfer_out)

    patch dismiss_transaction_receipt_link_path(entries(:transfer_out), receipt_link)

    assert_response :success
    assert_equal "dismissed", receipt_link.reload.status
  end

  test "destroy unlinks the receipt" do
    receipt_link = receipt_links(:linked_one)

    assert_difference "ReceiptLink.count", -1 do
      delete transaction_receipt_link_path(entries(:transaction), receipt_link)
    end

    assert_response :success
  end

  test "a user without annotate permission on the account is refused" do
    sign_in users(:family_member)
    receipt_link = receipt_links(:dismissed_transfer_in)

    patch confirm_transaction_receipt_link_path(entries(:transfer_in), receipt_link)

    assert_redirected_to transaction_path(entries(:transfer_in))
    assert_equal "dismissed", receipt_link.reload.status
  end

  test "a transaction in another family 404s" do
    sign_in users(:empty)

    get transaction_receipt_links_path(entries(:transaction))

    assert_response :not_found
  end
end
