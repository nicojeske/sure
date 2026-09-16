require "test_helper"

class Receipts::DocumentLinksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @connection = paperless_connections(:one)
    sign_in @user
  end

  test "new renders candidates and search results" do
    stub_document(id: 501, title: "Grocery Receipt", content: "Total: 12.34", correspondent: 1)
    stub_correspondents(1 => "Grocery Store")
    build_transaction(amount: 12.34, name: "Grocery Store", date: Date.current)

    get new_receipts_document_link_path(document_id: 501)

    assert_response :success
    assert_select "body", text: /Grocery Receipt/
    assert_select "body", text: /Grocery Store/
  end

  test "new degrades gracefully when the document fetch fails" do
    Provider::Paperless.any_instance.stubs(:document).raises(Provider::Paperless::Error.new("boom", :not_found))

    get new_receipts_document_link_path(document_id: 999)

    assert_response :success
    assert_select "body", text: /Paperless resource not found/
  end

  test "create links the document to the chosen transaction" do
    transaction = build_transaction(amount: 45.67, name: "Hardware Shop", date: Date.current)
    stub_document(id: 502, title: "Hardware Receipt", content: "Total: 45.67", correspondent: nil)
    stub_correspondents({})
    stub_search([])

    assert_difference "ReceiptLink.count", 1 do
      post receipts_document_links_path(document_id: 502, entry_id: transaction.entry.id), as: :turbo_stream
    end

    assert_response :success
    link = ReceiptLink.find_by(transaction_record: transaction, document_id: 502)
    assert_equal "linked", link.status
    assert_equal "manual", link.source
  end

  test "create overrides a prior dismissal" do
    transaction = build_transaction(amount: 67.89, name: "Cafe", date: Date.current)
    ReceiptLink.create!(
      transaction_record: transaction, paperless_connection: @connection,
      document_id: 503, status: "dismissed", source: "auto"
    )
    stub_document(id: 503, title: "Cafe Receipt", content: "Total: 67.89", correspondent: nil)
    stub_correspondents({})
    stub_search([])

    post receipts_document_links_path(document_id: 503, entry_id: transaction.entry.id), as: :turbo_stream

    link = ReceiptLink.find_by(transaction_record: transaction, document_id: 503)
    assert_equal "linked", link.status
    assert_equal "manual", link.source
  end

  test "create denies linking to a transaction on an account the user cannot annotate" do
    transaction = build_transaction(amount: 12.00, name: "Someone else's", date: Date.current)
    transaction.entry.account.update!(owner: users(:family_member))
    stub_document(id: 504, title: "Doc", content: "", correspondent: nil)
    stub_correspondents({})

    assert_no_difference "ReceiptLink.count" do
      post receipts_document_links_path(document_id: 504, entry_id: transaction.entry.id), as: :turbo_stream
    end
  end

  test "new returns 404 without a configured connection" do
    @connection.destroy

    get new_receipts_document_link_path(document_id: 505)

    assert_response :not_found
  end

  private
    def build_transaction(amount:, name:, date:, currency: "USD")
      transaction = Transaction.new
      accounts(:depository).entries.create!(name: name, date: date, amount: amount, currency: currency, entryable: transaction)
      transaction
    end

    def stub_document(id:, title:, content:, correspondent:, custom_fields: [])
      Provider::Paperless.any_instance.stubs(:document).returns(
        "id" => id, "title" => title, "content" => content, "created" => Date.current.iso8601,
        "correspondent" => correspondent, "mime_type" => "application/pdf", "custom_fields" => custom_fields
      )
    end

    def stub_correspondents(hash)
      Provider::Paperless.any_instance.stubs(:correspondents).returns(hash)
    end

    def stub_search(documents)
      Provider::Paperless.any_instance.stubs(:search_documents).returns("count" => documents.size, "results" => documents)
    end
end
