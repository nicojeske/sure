require "test_helper"

class ReceiptLinksControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "index renders linked and suggested receipt links" do
    get transaction_receipt_links_path(entries(:transaction))

    assert_response :success
    assert_select "#" + ActionView::RecordIdentifier.dom_id(transactions(:one), :receipt_links)
  end

  test "index auto-triggers a scan and renders a searching state for a never-scanned transaction" do
    entry = create_transaction(date: 1.day.ago.to_date, kind: "standard")

    assert_enqueued_with(job: PaperlessAutoLinkJob, args: [ entry.transaction.id ]) do
      get transaction_receipt_links_path(entry)
    end

    assert_response :success
    assert_select "p", text: /Searching Paperless/
  end

  test "index does not auto-trigger a scan for an already-scanned transaction" do
    entry = create_transaction(date: 1.day.ago.to_date, kind: "standard")
    entry.transaction.update_column(:receipt_scanned_at, Time.current)

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      get transaction_receipt_links_path(entry)
    end
  end

  test "index does not auto-trigger a scan when auto_link_enabled is false" do
    @connection.update!(auto_link_enabled: false)
    entry = create_transaction(date: 1.day.ago.to_date, kind: "standard")

    assert_no_enqueued_jobs(only: PaperlessAutoLinkJob) do
      get transaction_receipt_links_path(entry)
    end
  end

  test "new renders the search modal with stubbed results" do
    Provider::Paperless.any_instance.expects(:search_documents).returns(
      "results" => [ { "id" => 501, "title" => "Coffee Receipt", "created" => "2026-07-01", "correspondent" => 7 } ],
      "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns(7 => "Cafe")

    get new_transaction_receipt_link_path(entries(:transaction))

    assert_response :success
    assert_select "turbo-frame#paperless_search_results"
    assert_select "p", text: "Coffee Receipt"
  end

  test "new renders an error state when Paperless is unreachable" do
    Provider::Paperless.any_instance.expects(:search_documents).raises(Provider::Paperless::Error.new("down", :unreachable))

    get new_transaction_receipt_link_path(entries(:transaction))

    assert_response :success
    assert_select "turbo-frame#paperless_search_results" do
      assert_select "p", text: /Could not reach Paperless/
    end
  end

  test "new shows the amount and same-amount pill for a document with custom fields, and still shows a Link button for one without" do
    @connection.update!(total_amount_field_id: 2)
    Provider::Paperless.any_instance.expects(:search_documents).returns(
      "results" => [
        { "id" => 501, "title" => "Coffee Receipt", "created" => "2026-07-01", "correspondent" => 7,
          "custom_fields" => [ { "field" => 2, "value" => "USD10.00" } ] },
        { "id" => 502, "title" => "Plain Receipt", "created" => "2026-07-01", "correspondent" => nil, "custom_fields" => [] }
      ],
      "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns(7 => "Cafe")
    Provider::Paperless.any_instance.expects(:custom_fields).returns(
      2 => { "name" => "Betrag", "data_type" => "monetary", "currency" => "USD" }
    )

    get new_transaction_receipt_link_path(entries(:transaction))

    assert_response :success
    assert_select "p", text: "Coffee Receipt"
    assert_select "span", text: "$10.00"
    assert_select "p", text: "Plain Receipt"
    assert_select "button", text: /Link/, count: 2
  end

  test "new 404s when the family has no configured connection" do
    @connection.destroy

    get new_transaction_receipt_link_path(entries(:transaction))

    assert_response :not_found
  end

  test "create links a document and caches its metadata" do
    Provider::Paperless.any_instance.expects(:document).with("501").returns(
      "id" => 501, "title" => "Coffee Receipt", "created" => "2026-07-01", "correspondent" => 7, "mime_type" => "application/pdf"
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns(7 => "Cafe")

    assert_difference "ReceiptLink.count", 1 do
      post transaction_receipt_links_path(entries(:transaction), document_id: "501")
    end

    assert_response :success
    link = ReceiptLink.find_by(document_id: 501)
    assert_equal "linked", link.status
    assert_equal "manual", link.source
    assert_equal "Coffee Receipt", link.document_title
    assert_equal "Cafe", link.document_correspondent
    # The pill lives in the transactions list, outside the drawer's receipt_links frame replaced
    # above — assert it's refreshed too, so linking from the drawer shows the pill without a reload.
    assert_select "turbo-stream[action=replace][target=?]", ActionView::RecordIdentifier.dom_id(transactions(:one), :receipt_pill)
  end

  test "create with an already linked document_id is idempotent" do
    existing = receipt_links(:linked_one)
    Provider::Paperless.any_instance.expects(:document).with(existing.document_id.to_s).returns(
      "id" => existing.document_id, "title" => "Starbucks Receipt", "created" => "2026-07-01", "correspondent" => nil, "mime_type" => "application/pdf"
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns({})

    assert_no_difference "ReceiptLink.count" do
      post transaction_receipt_links_path(entries(:transaction), document_id: existing.document_id.to_s)
    end

    assert_response :success
    assert_equal "linked", existing.reload.status
  end

  test "confirm promotes a suggestion to linked" do
    receipt_link = receipt_links(:suggested_transfer_out)

    patch confirm_transaction_receipt_link_path(entries(:transfer_out), receipt_link)

    assert_response :success
    assert_equal "linked", receipt_link.reload.status
    assert_select "turbo-stream[action=replace][target=?]", ActionView::RecordIdentifier.dom_id(transactions(:transfer_out), :receipt_pill)
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
    assert_select "turbo-stream[action=replace][target=?]", ActionView::RecordIdentifier.dom_id(transactions(:one), :receipt_pill)
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
