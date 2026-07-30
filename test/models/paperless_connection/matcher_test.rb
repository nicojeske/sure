require "test_helper"

class PaperlessConnection::MatcherTest < ActiveSupport::TestCase
  setup do
    @connection = paperless_connections(:one) # match_window_days: 3, min_auto_link_score: 0.9
    @account = accounts(:depository)
    @matcher = PaperlessConnection::Matcher.new(@connection)
  end

  test "exact amount, same date, and matching correspondent auto-links" do
    transaction = build_transaction(amount: 10, name: "Starbucks", date: Date.current)

    stub_search([ document(id: 501, content: "Total: 10.00", created: Date.current, correspondent: 1, title: "Starbucks Receipt") ])
    stub_correspondents(1 => "Starbucks")

    @matcher.match!(transaction)

    link = transaction.receipt_links.sole
    assert_equal "linked", link.status
    assert_equal "auto", link.source
    assert_equal 501, link.document_id
    assert transaction.reload.receipt_scanned_at.present?
  end

  test "matches EU-formatted amount 1.234,56 against a 1234.56 transaction" do
    transaction = build_transaction(amount: 1234.56, name: "Big Purchase", date: Date.current)

    stub_search([ document(id: 601, content: "Betrag: 1.234,56 EUR", created: Date.current, correspondent: nil) ])
    stub_correspondents({})

    candidates = @matcher.candidates_for(transaction)

    assert_equal 1, candidates.size
    assert candidates.first.reasons["amount"]
  end

  test "boundary guard: 12.34 does not match inside 312.345" do
    transaction = build_transaction(amount: 12.34, name: "Snack", date: Date.current)

    stub_search([ document(id: 701, content: "Reference 312.345", created: Date.current, correspondent: nil) ])
    stub_correspondents({})

    candidates = @matcher.candidates_for(transaction)

    assert candidates.none? { |candidate| candidate.reasons["amount"] }
  end

  test "two equally strong candidates become two suggestions, nothing linked" do
    transaction = build_transaction(amount: 50, name: "Office Supplies", date: Date.current)

    stub_search([
      document(id: 801, content: "Total: 50.00", created: Date.current, correspondent: 1, title: "Invoice A"),
      document(id: 802, content: "Total: 50.00", created: Date.current, correspondent: 1, title: "Invoice B")
    ])
    stub_correspondents(1 => "Office Supplies")

    @matcher.match!(transaction)

    assert_equal 0, transaction.receipt_links.linked.count
    assert_equal 2, transaction.receipt_links.suggested.count
  end

  test "zero documents returned stamps receipt_scanned_at without creating links" do
    transaction = build_transaction(amount: 20, name: "Nothing found", date: Date.current)

    stub_search([])

    @matcher.match!(transaction)

    assert_equal 0, transaction.receipt_links.count
    assert transaction.reload.receipt_scanned_at.present?
  end

  test "an already-dismissed document is not re-suggested" do
    transaction = build_transaction(amount: 30, name: "Repeat scan", date: Date.current)
    ReceiptLink.create!(
      transaction_record: transaction, paperless_connection: @connection,
      document_id: 901, status: "dismissed", source: "manual"
    )

    stub_search([ document(id: 901, content: "Total: 30.00", created: Date.current, correspondent: nil) ])
    stub_correspondents({})

    @matcher.match!(transaction)

    link = ReceiptLink.find_by(transaction_record: transaction, document_id: 901)
    assert_equal "dismissed", link.status
  end

  test "an existing linked row is left untouched on re-run" do
    transaction = build_transaction(amount: 40, name: "Already linked", date: Date.current)
    ReceiptLink.create!(
      transaction_record: transaction, paperless_connection: @connection,
      document_id: 902, status: "linked", source: "manual", score: 0.5,
      document_title: "Original Title"
    )

    stub_search([ document(id: 902, content: "Total: 40.00", created: Date.current, correspondent: nil, title: "Renamed") ])
    stub_correspondents({})

    @matcher.match!(transaction)

    link = ReceiptLink.find_by(transaction_record: transaction, document_id: 902)
    assert_equal "linked", link.status
    assert_equal "manual", link.source
    assert_equal "Original Title", link.document_title
  end

  test "a structured total matching the transaction scores 0.55 and auto-links" do
    map_amount_fields
    transaction = build_transaction(amount: 23.42, name: "Netto", date: Date.current, currency: "EUR")

    stub_search([
      document(id: 1001, content: "", created: Date.current, correspondent: 1, title: "Netto receipt",
               custom_fields: [ { "field" => 2, "value" => "EUR23.42" } ])
    ])
    stub_correspondents(1 => "Netto")
    stub_custom_fields

    candidates = @matcher.candidates_for(transaction)

    # Same-day date match (0.25) + exact correspondent match (0.20) + structured amount (0.55) = 1.0
    assert_equal 1.0, candidates.first.score
    assert candidates.first.reasons["amount"]

    @matcher.match!(transaction)
    assert_equal "linked", transaction.receipt_links.sole.status
  end

  test "a structured total that conflicts with the transaction amount scores no amount points, is flagged, and only suggests" do
    map_amount_fields
    transaction = build_transaction(amount: 19.90, name: "Netto", date: Date.current, currency: "EUR")

    stub_search([
      document(id: 1002, content: "", created: Date.current, correspondent: 1, title: "Netto receipt",
               custom_fields: [ { "field" => 2, "value" => "EUR23.42" } ])
    ])
    stub_correspondents(1 => "Netto")
    stub_custom_fields

    candidates = @matcher.candidates_for(transaction)
    assert candidates.first.reasons["amount_conflict"]
    assert_not candidates.first.reasons["amount"]

    @matcher.match!(transaction)
    link = transaction.receipt_links.sole
    assert_equal "suggested", link.status
    assert link.match_reasons["amount_conflict"]
  end

  test "the net field matching (while the total field does not) scores the weaker secondary weight" do
    map_amount_fields
    transaction = build_transaction(amount: 21.39, name: "Netto", date: Date.current, currency: "EUR")

    stub_search([
      document(id: 1003, content: "", created: Date.current, correspondent: nil,
               custom_fields: [ { "field" => 2, "value" => "EUR23.42" }, { "field" => 3, "value" => "EUR21.39" } ])
    ])
    stub_correspondents({})
    stub_custom_fields

    candidates = @matcher.candidates_for(transaction)

    assert candidates.first.reasons["amount_secondary"]
    assert_not candidates.first.reasons["amount"]
  end

  test "a document with no custom fields still matches via OCR" do
    map_amount_fields
    transaction = build_transaction(amount: 10, name: "Cafe", date: Date.current)

    stub_search([ document(id: 1004, content: "Total: 10.00", created: Date.current, correspondent: nil) ])
    stub_correspondents({})
    stub_custom_fields

    candidates = @matcher.candidates_for(transaction)

    assert candidates.first.reasons["amount"]
  end

  test "the second, amount-targeted search finds a document outside the date window and merges without duplicating" do
    map_amount_fields
    transaction = build_transaction(amount: 205.87, name: "JetBrains", date: Date.current, currency: "EUR")

    outside_window_doc = document(id: 775, content: "", created: Date.current - 20.days, correspondent: nil,
                                   custom_fields: [ { "field" => 2, "value" => "EUR205.87" } ])

    Provider::Paperless.any_instance.stubs(:search_documents).with do |opts|
      opts[:custom_field_query].nil?
    end.returns({ "results" => [] })

    Provider::Paperless.any_instance.stubs(:search_documents).with do |opts|
      opts[:custom_field_query].present?
    end.returns({ "results" => [ outside_window_doc ] })

    stub_correspondents({})
    stub_custom_fields

    candidates = @matcher.candidates_for(transaction)

    assert_equal 1, candidates.size
    assert_equal 775, candidates.first.document["id"]
  end

  test "no second search is issued when no monetary field is mapped" do
    transaction = build_transaction(amount: 10, name: "Cafe", date: Date.current)

    Provider::Paperless.any_instance.expects(:search_documents).once.returns({ "results" => [] })

    @matcher.candidates_for(transaction)
  end

  private
    def build_transaction(amount:, name:, date:, currency: "USD")
      transaction = Transaction.new
      @account.entries.create!(name: name, date: date, amount: amount, currency: currency, entryable: transaction)
      transaction
    end

    def document(id:, content:, created:, correspondent:, title: "Document #{id}", mime_type: "application/pdf", custom_fields: [])
      {
        "id" => id,
        "title" => title,
        "content" => content,
        "created" => created.iso8601,
        "correspondent" => correspondent,
        "mime_type" => mime_type,
        "custom_fields" => custom_fields
      }
    end

    def stub_search(results)
      Provider::Paperless.any_instance.stubs(:search_documents).returns({ "results" => results })
    end

    def stub_correspondents(hash)
      Provider::Paperless.any_instance.stubs(:correspondents).returns(hash)
    end

    def stub_custom_fields
      Provider::Paperless.any_instance.stubs(:custom_fields).returns(
        2 => { "name" => "Betrag", "data_type" => "monetary", "currency" => "EUR" },
        3 => { "name" => "Netto-Betrag", "data_type" => "monetary", "currency" => "EUR" },
        4 => { "name" => "MwSt-Betrag", "data_type" => "monetary", "currency" => "EUR" }
      )
    end

    def map_amount_fields
      @connection.update!(total_amount_field_id: 2, net_amount_field_id: 3, tax_amount_field_id: 4)
    end
end
