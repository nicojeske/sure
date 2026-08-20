require "test_helper"

class ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "index lists linked receipt links by default" do
    get receipts_path

    assert_response :success
    assert_includes rendered_links, receipt_links(:linked_one)
    assert_not_includes rendered_links, receipt_links(:suggested_transfer_out)
    assert_not_includes rendered_links, receipt_links(:dismissed_transfer_in)
    assert_select "body", text: /Starbucks Receipt/
  end

  test "index filters by status" do
    get receipts_path(status: "suggested")

    assert_response :success
    assert_includes rendered_links, receipt_links(:suggested_transfer_out)
    assert_not_includes rendered_links, receipt_links(:linked_one)
  end

  test "index status all includes every match" do
    get receipts_path(status: "all")

    assert_response :success
    assert_includes rendered_links, receipt_links(:linked_one)
    assert_includes rendered_links, receipt_links(:suggested_transfer_out)
    assert_includes rendered_links, receipt_links(:dismissed_transfer_in)
  end

  test "index filters by source" do
    manual = ReceiptLink.create!(
      transaction_record: transactions(:one),
      paperless_connection: @connection,
      document_id: 501,
      status: "linked",
      source: "manual"
    )

    get receipts_path(source: "manual")

    assert_response :success
    assert_includes rendered_links, manual
    assert_not_includes rendered_links, receipt_links(:linked_one)
  end

  test "index falls back to defaults for unrecognized filter values" do
    get receipts_path(status: "bogus", source: "bogus")

    assert_response :success
    assert_includes rendered_links, receipt_links(:linked_one)
    assert_not_includes rendered_links, receipt_links(:suggested_transfer_out)
  end

  test "index orders newest match first" do
    newest = ReceiptLink.create!(
      transaction_record: transactions(:one),
      paperless_connection: @connection,
      document_id: 502,
      status: "linked"
    )

    get receipts_path

    assert_response :success
    assert_equal newest, rendered_links.first
  end

  test "index excludes receipt links on accounts the user cannot access" do
    entries(:transaction).account.update!(owner: users(:family_member))

    get receipts_path

    assert_response :success
    assert_not_includes rendered_links, receipt_links(:linked_one)
  end

  test "index renders the recipient and the row actions for a suggestion" do
    link = receipt_links(:suggested_transfer_out)

    get receipts_path(status: "suggested")

    assert_response :success
    assert_select "tr#" + ActionView::RecordIdentifier.dom_id(link)
    assert_select "th", text: "Recipient"
    assert_select "form[action=?]", confirm_receipts_link_path(link, status: "suggested", source: "all")
    assert_select "form[action=?]", dismiss_receipts_link_path(link, status: "suggested", source: "all")
  end

  test "index offers unlink but not confirm for an already linked match" do
    link = receipt_links(:linked_one)

    get receipts_path

    assert_response :success
    # Recipient column is the transaction's merchant, not the Paperless correspondent.
    assert_equal "Amazon", link.transaction_record.merchant.name
    assert_select "tr#" + ActionView::RecordIdentifier.dom_id(link) + " td", text: "Amazon"
    assert_select "form[action=?]", receipts_link_path(link, status: "linked", source: "all")
    assert_select "form[action=?]", confirm_receipts_link_path(link, status: "linked", source: "all"), count: 0
    assert_select "form[action=?]", dismiss_receipts_link_path(link, status: "linked", source: "all")
  end

  test "index renders the not-connected empty state without a configured connection" do
    @connection.destroy

    get receipts_path

    assert_response :success
    assert_select "body", text: /Paperless-ngx is not connected/
  end

  private
    def rendered_links
      @controller.view_assigns["receipt_links"].to_a
    end
end
