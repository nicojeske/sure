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
