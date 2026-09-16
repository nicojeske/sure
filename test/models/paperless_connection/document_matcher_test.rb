require "test_helper"

class PaperlessConnection::DocumentMatcherTest < ActiveSupport::TestCase
  setup do
    @connection = paperless_connections(:one) # sweep_window_days: 30 (schema default), min_auto_link_score: 0.7
    @account = accounts(:depository)
    @matcher = PaperlessConnection::DocumentMatcher.new(@connection)
  end

  # NOTE: candidate_transactions scopes to the *whole family*, unlike the forward Matcher (which
  # only ever looks at documents for one already-known transaction). dylan_family's fixtures
  # include Transaction entries at amounts 10, 100 and -100 (test/fixtures/entries.yml) that are
  # NOT excluded by the transfer-kind filter (a pre-existing fixture/kind mismatch — see
  # AGENTS.md-linked notes on Transaction::TRANSFER_KINDS). Every amount below is chosen to avoid
  # those values so a test's expected candidate count can't be perturbed by fixture data.

  test "a single confident match auto-links" do
    transaction = build_transaction(amount: 12.34, name: "Grocery Store", date: Date.current)
    stub_correspondents(1 => "Grocery Store")
    doc = document(id: 501, content: "Total: 12.34", created: Date.current, correspondent: 1, title: "Grocery Receipt")

    result = @matcher.match!(doc)

    link = transaction.receipt_links.sole
    assert_equal "linked", link.status
    assert_equal "auto", link.source
    assert_equal 501, link.document_id
    assert_equal :linked, result.outcome
  end

  # The whole point of the 0.9 -> 0.7 default change: an OCR amount match plus an exact date no
  # longer needs a correspondent match on top to clear the auto-link bar (0.45 + 0.25 = 0.70).
  test "amount and exact date alone, with no correspondent signal, clears the lowered auto-link threshold" do
    transaction = build_transaction(amount: 88.20, name: "Unknown Shop", date: Date.current)
    stub_correspondents({})
    doc = document(id: 507, content: "Total: 88.20", created: Date.current, correspondent: nil)

    result = @matcher.match!(doc)

    assert_equal :linked, result.outcome
    link = transaction.receipt_links.sole
    assert_equal 0.70, link.score
  end

  test "does not stamp receipt_scanned_at" do
    transaction = build_transaction(amount: 45.67, name: "Hardware Shop", date: Date.current)
    stub_correspondents(1 => "Hardware Shop")
    doc = document(id: 502, content: "Total: 45.67", created: Date.current, correspondent: 1, title: "Hardware Receipt")

    @matcher.match!(doc)

    assert_nil transaction.reload.receipt_scanned_at
  end

  test "two equally strong candidate transactions become two suggestions, nothing linked" do
    build_transaction(amount: 78.90, name: "Office Supplies A", date: Date.current)
    build_transaction(amount: 78.90, name: "Office Supplies B", date: Date.current)
    stub_correspondents(1 => "Office Supplies")
    doc = document(id: 801, content: "Total: 78.90", created: Date.current, correspondent: 1, title: "Invoice")

    result = @matcher.match!(doc)

    assert_equal :suggested, result.outcome
    assert_equal 0, ReceiptLink.where(document_id: 801, status: "linked").count
    assert_equal 2, ReceiptLink.where(document_id: 801, status: "suggested").count
  end

  test "a transaction with no amount signal is never a candidate" do
    build_transaction(amount: 15.00, name: "Grocery Store", date: Date.current)
    stub_correspondents(1 => "Grocery Store")
    # No amount anywhere in the OCR content that matches the transaction.
    doc = document(id: 503, content: "Just a note, no total here", created: Date.current, correspondent: 1)

    candidates = @matcher.candidates_for(doc)

    assert_empty candidates
  end

  test "OCR-only document scores 0.45 for the amount component" do
    transaction = build_transaction(amount: 1234.56, name: "Big Purchase", date: Date.current)
    stub_correspondents({})
    doc = document(id: 601, content: "Betrag: 1.234,56 EUR", created: Date.current, correspondent: nil)

    candidates = @matcher.candidates_for(doc)

    assert_equal 1, candidates.size
    assert_equal transaction, candidates.first.transaction
    assert candidates.first.reasons["amount"]
  end

  test "a structured total narrows candidates to matching-amount transactions only" do
    map_amount_fields
    matching = build_transaction(amount: 23.42, name: "Netto", date: Date.current, currency: "EUR")
    build_transaction(amount: 99.99, name: "Other", date: Date.current, currency: "EUR")
    stub_correspondents(1 => "Netto")
    stub_custom_fields
    doc = document(id: 1001, content: "", created: Date.current, correspondent: 1, title: "Netto receipt",
                   custom_fields: [ { "field" => 2, "value" => "EUR23.42" } ])

    candidates = @matcher.candidates_for(doc)

    assert_equal 1, candidates.size
    assert_equal matching, candidates.first.transaction
    assert_equal 1.0, candidates.first.score
  end

  test "a transaction outside the sweep window is not a candidate even with a matching amount" do
    @connection.update!(sweep_window_days: 5)
    build_transaction(amount: 321.99, name: "Old Purchase", date: Date.current - 30.days)
    stub_correspondents({})
    doc = document(id: 504, content: "Total: 321.99", created: Date.current, correspondent: nil)

    candidates = @matcher.candidates_for(doc)

    assert_empty candidates
  end

  test "a document with no parseable date returns no candidates" do
    build_transaction(amount: 11.11, name: "Some Shop", date: Date.current)
    stub_correspondents({})
    doc = document(id: 505, content: "Total: 11.11", created: nil, correspondent: nil)

    assert_empty @matcher.candidates_for(doc)
  end

  test "an already-dismissed document is not re-suggested or re-linked" do
    transaction = build_transaction(amount: 67.89, name: "Local Cafe", date: Date.current)
    ReceiptLink.create!(
      transaction_record: transaction, paperless_connection: @connection,
      document_id: 506, status: "dismissed", source: "manual"
    )
    stub_correspondents(1 => "Local Cafe")
    doc = document(id: 506, content: "Total: 67.89", created: Date.current, correspondent: 1)

    @matcher.match!(doc)

    link = ReceiptLink.find_by(transaction_record: transaction, document_id: 506)
    assert_equal "dismissed", link.status
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
        "created" => created&.iso8601,
        "correspondent" => correspondent,
        "mime_type" => mime_type,
        "custom_fields" => custom_fields
      }
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
