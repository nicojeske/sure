require "test_helper"

class Transaction::AnnotationSuggesterTest < ActiveSupport::TestCase
  include EntriesTestHelper

  Suggester = Transaction::AnnotationSuggester
  Annotation = Provider::LlmConcept::TransactionAnnotation
  Part = Provider::LlmConcept::TransactionAnnotationSplit

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @entry = create_transaction(name: "AMAZON MKTPL 123", amount: 20, currency: "USD")
    @kitchen = @family.categories.create!(name: "Kitchen", color: "#00ff00")
    @outdoor = @family.categories.create!(name: "Outdoor", color: "#0000ff")
    @provider = mock("llm")
    Provider::Registry.stubs(:preferred_llm_provider).returns(@provider)
  end

  test "resolves names to the family's own records and drops unknown ones" do
    stub_annotation(annotation(
      category_name: "kitchen", merchant_name: "amazon", tag_names: [ "Trips", "Invented" ]
    ))

    payload = suggester.suggest_from_hint(@entry, "corer").payload

    assert_equal @kitchen.id, payload["category_id"]
    assert_equal merchants(:amazon).id, payload["merchant_id"]
    assert_nil payload["new_merchant_name"]
    assert_equal [ tags(:one).id ], payload["tag_ids"]
  end

  test "an unknown merchant is proposed as new and an invented category is dropped" do
    stub_annotation(annotation(category_name: "Gadgets", merchant_name: "Manufactum"))

    payload = suggester.suggest_from_hint(@entry, "corer").payload

    assert_nil payload["category_id"]
    assert_nil payload["merchant_id"]
    assert_equal "Manufactum", payload["new_merchant_name"]
  end

  test "keeps a split that adds up across two categories" do
    stub_annotation(annotation(split: [ part("Corer", 12, "Kitchen"), part("Hand warmer", 8, "Outdoor") ]))

    split = suggester.suggest_from_hint(@entry, "Corer 12 + Hand warmer 8").payload["split"]

    assert_equal [ "12.0", "8.0" ], split.map { |row| row["amount"] }
    assert_equal [ @kitchen.id, @outdoor.id ], split.map { |row| row["category_id"] }
  end

  test "spreads a small difference across split parts in proportion" do
    stub_annotation(annotation(split: [ part("Corer", 12, "Kitchen"), part("Hand warmer", 7.6, "Outdoor") ]))

    split = suggester.suggest_from_hint(@entry, "Corer 12 + Hand warmer 7.60").payload["split"]

    assert_equal BigDecimal("20"), split.sum { |row| row["amount"].to_d }
  end

  test "drops a split that is one category, does not add up, or is on a split part" do
    stub_annotation(annotation(split: [ part("A", 12, "Kitchen"), part("B", 8, "Kitchen") ]))
    assert_nil suggester.suggest_from_hint(@entry, "a").payload["split"]

    stub_annotation(annotation(split: [ part("A", 12, "Kitchen"), part("B", 3, "Outdoor") ]))
    assert_nil suggester.suggest_from_hint(@entry, "b").payload["split"]

    child = @entry.split!([ { name: "x", amount: 10 }, { name: "y", amount: 10 } ]).first
    stub_annotation(annotation(split: [ part("A", 5, "Kitchen"), part("B", 5, "Outdoor") ]))
    assert_nil suggester.suggest_from_hint(child, "c").payload["split"]
  end

  test "the same hint is answered from the stored suggestion without a second call" do
    @provider.expects(:suggest_transaction_annotation).once.returns(success(annotation(name: "Corer")))

    first = suggester.suggest_from_hint(@entry, "Corer")
    second = suggester.suggest_from_hint(@entry, "  corer ")

    assert_equal first, second
    assert first.ready?
  end

  test "passes reviewed transactions with the same name or merchant as examples" do
    reviewed = create_transaction(name: "AMAZON MKTPL 123", category: @kitchen, notes: "Kitchen stuff")
    reviewed.mark_reviewed!(@user)
    create_transaction(name: "AMAZON MKTPL 123")
    create_transaction(name: "Something else").mark_reviewed!(@user)

    @provider.expects(:suggest_transaction_annotation).with do |**args|
      assert_equal [ { name: "AMAZON MKTPL 123", category: "Kitchen", tags: [], notes: "Kitchen stuff" } ], args[:examples]
      true
    end.returns(success(annotation))

    suggester.suggest_from_hint(@entry, "corer")
  end

  test "stored values use the family's AI content language and the rationale the reviewer's language" do
    @family.update!(locale: "fr", ai_content_language: "de")
    @user.update!(locale: "en")

    @provider.expects(:suggest_transaction_annotation).with do |**args|
      assert_equal "de", args[:content_locale]
      assert_equal "en", args[:locale]
      true
    end.returns(success(annotation))

    suggester.suggest_from_hint(@entry, "corer")
  end

  test "without an AI content language stored values follow the reviewer's interface language" do
    @family.update!(locale: "fr", ai_content_language: nil)
    @user.update!(locale: "en")

    @provider.expects(:suggest_transaction_annotation).with do |**args|
      assert_equal "en", args[:content_locale]
      assert_equal "en", args[:locale]
      true
    end.returns(success(annotation))

    suggester.suggest_from_hint(@entry, "corer")
  end

  test "tells the provider which fields a rule set" do
    @entry.transaction.enrich_attribute(:category_id, @kitchen.id, source: "rule")

    @provider.expects(:suggest_transaction_annotation).with do |**args|
      assert_equal %w[category], args[:rule_set_fields]
      true
    end.returns(success(annotation))

    suggester.suggest_from_hint(@entry, "corer")
  end

  test "a receipt suggestion, as prefetched without a hint, drops proposals for rule-set fields" do
    entry = receipt_links(:linked_one).transaction_record.entry
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "Latte 3.50" })
    entry.transaction.enrich_attribute(:category_id, @kitchen.id, source: "rule")
    entry.transaction.enrich_attribute(:merchant_id, @family.merchants.create!(name: "Edeka").id, source: "rule")
    entry.transaction.enrich_attribute(:tag_ids, [ tags(:one).id ], source: "rule")
    stub_annotation(annotation(
      name: "Latte", notes: "Oat milk", category_name: "Outdoor", merchant_name: "Starbucks", tag_names: [ "Trips" ]
    ))

    payload = suggester.suggest_from_receipt(entry.reload, receipt_links(:linked_one)).payload

    assert_nil payload["category_id"]
    assert_nil payload["merchant_id"]
    assert_nil payload["new_merchant_name"]
    assert_equal [], payload["tag_ids"]
    assert_equal "Latte", payload["name"]
    assert_equal "Oat milk", payload["notes"]
  end

  test "a hint may change rule-set fields" do
    @entry.transaction.enrich_attribute(:category_id, @kitchen.id, source: "rule")
    @entry.enrich_attribute(:name, "Kitchen stuff", source: "rule")
    stub_annotation(annotation(name: "Hand warmer", category_name: "Outdoor"))

    payload = suggester.suggest_from_hint(@entry.reload, "this time it's a hand warmer").payload

    assert_equal @outdoor.id, payload["category_id"]
    assert_equal "Hand warmer", payload["name"]
  end

  test "a rule proposal from a hint resolves names to this family's records" do
    eon = @family.merchants.create!(name: "EON")
    stub_annotation(annotation(rule_proposal: proposal(
      conditions: [ condition("merchant", "=", "eon"), condition("amount", ">", "10.5") ],
      actions: [ action("category", "kitchen"), action("tags", [ "Trips", "Invented" ]), action("name", "Strom") ]
    )))

    rule = suggester.suggest_from_hint(@entry, "always map EON to Kitchen").payload["rule_proposal"]

    assert_equal [
      { "condition_type" => "transaction_merchant", "operator" => "=", "value" => eon.id },
      { "condition_type" => "transaction_amount", "operator" => ">", "value" => "10.5" }
    ], rule["conditions"]
    assert_equal [
      { "action_type" => "set_transaction_category", "value" => @kitchen.id },
      { "action_type" => "set_transaction_tags", "value" => [ tags(:one).id ] },
      { "action_type" => "set_transaction_name", "value" => "Strom" }
    ], rule["actions"]
    assert_equal "merchant:#{eon.id}", rule["pattern_key"]
  end

  test "a name condition keys the proposal by its lowercase text" do
    stub_annotation(annotation(rule_proposal: proposal(
      conditions: [ condition("name", "like", "EON Abschlag") ], actions: [ action("category", "Kitchen") ]
    )))

    rule = suggester.suggest_from_hint(@entry, "make a rule").payload["rule_proposal"]

    assert_equal "name:eon abschlag", rule["pattern_key"]
  end

  test "a rule proposal drops notes, unsupported and unresolvable parts" do
    stub_annotation(annotation(rule_proposal: proposal(
      conditions: [ condition("name", "like", "EON"), condition("notes", "like", "x"), condition("merchant", "=", "Nobody"), condition("amount", "like", "abc") ],
      actions: [ action("notes", "hi"), action("category", "Gadgets"), action("merchant", "Nobody"), action("category", "Outdoor") ]
    )))

    rule = suggester.suggest_from_hint(@entry, "always").payload["rule_proposal"]

    assert_equal [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "EON" } ], rule["conditions"]
    assert_equal [ { "action_type" => "set_transaction_category", "value" => @outdoor.id } ], rule["actions"]
  end

  test "a rule proposal without conditions or without actions is no proposal" do
    stub_annotation(annotation(rule_proposal: proposal(conditions: [ condition("notes", "like", "x") ], actions: [ action("category", "Kitchen") ])))
    assert_nil suggester.suggest_from_hint(@entry, "a").payload["rule_proposal"]

    stub_annotation(annotation(rule_proposal: proposal(conditions: [ condition("name", "like", "EON") ], actions: [ action("notes", "x") ])))
    assert_nil suggester.suggest_from_hint(@entry, "b").payload["rule_proposal"]
  end

  test "no rule intent means no rule proposal, and a receipt run never has one" do
    stub_annotation(annotation(name: "Corer"))
    assert_nil suggester.suggest_from_hint(@entry, "corer").payload["rule_proposal"]

    entry = receipt_links(:linked_one).transaction_record.entry
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "Latte 3.50" })
    stub_annotation(annotation(rule_proposal: proposal(conditions: [ condition("name", "like", "EON") ], actions: [ action("category", "Kitchen") ])))
    assert_nil suggester.suggest_from_receipt(entry, receipt_links(:linked_one)).payload["rule_proposal"]
  end

  test "a provider failure is recorded on the suggestion and in the debug log" do
    @provider.stubs(:suggest_transaction_annotation).returns(Provider::Response.new(success?: false, data: nil, error: Provider::Error.new("boom")))

    suggestion = assert_difference "DebugLogEntry.count", 1 do
      suggester.suggest_from_hint(@entry, "corer")
    end

    assert suggestion.failed?
    assert_match "boom", suggestion.error
  end

  test "an unexpected error marks the suggestion failed and is logged with its provider" do
    @provider.stubs(:suggest_transaction_annotation).raises(Faraday::ConnectionFailed.new("down"))

    suggestion = suggester.suggest_from_hint(@entry, "corer")

    assert suggestion.failed?
    assert_match "down", suggestion.error
    log = DebugLogEntry.order(:created_at).last
    assert_equal "ai_annotation", log.category
    assert log.provider_key.present?
    assert_equal suggestion.id, log.metadata["suggestion_id"]
  end

  test "a Paperless failure is logged under the paperless provider key" do
    link = receipt_links(:linked_one)
    Provider::Paperless.any_instance.stubs(:document).raises(Provider::Paperless::Error.new("unreachable", :unreachable))

    suggestion = suggester.suggest_from_receipt(link.transaction_record.entry, link)

    assert suggestion.failed?
    assert_equal "paperless", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "a receipt that belongs to another transaction fails only that suggestion" do
    @provider.expects(:suggest_transaction_annotation).never

    instance = suggester
    suggestion = instance.suggest_from_receipt(@entry, receipt_links(:linked_one))

    assert suggestion.failed?
    assert_nil suggestion.receipt_link
    assert_kind_of Suggester::ReceiptError, instance.last_error
  end

  test "a receipt from another family's Paperless connection is never read" do
    other = families(:empty).create_paperless_connection!(base_url: "https://other.example.com", api_token: "t")
    link = @entry.transaction.receipt_links.create!(paperless_connection: other, document_id: 5, status: "linked")
    Provider::Paperless.any_instance.expects(:document).never
    @provider.expects(:suggest_transaction_annotation).never

    assert suggester.suggest_from_hint(@entry, "x").failed?
    assert suggester.suggest_from_receipt(@entry, link).failed?
  end

  test "classifies failures as LLM or receipt failures" do
    assert Suggester.llm_failure?(Suggester::Error.new("Provider failed"))
    assert_not Suggester.llm_failure?(Suggester::ReceiptError.new("no OCR"))
    assert_not Suggester.llm_failure?(Provider::Paperless::Error.new("gone", :not_found))
  end

  test "an empty OCR text is a receipt failure" do
    link = receipt_links(:linked_one)
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "" })
    @provider.expects(:suggest_transaction_annotation).never
    instance = suggester

    assert instance.suggest_from_receipt(link.transaction_record.entry, link).failed?
    assert_kind_of Suggester::ReceiptError, instance.last_error
  end

  test "a concurrent insert of the same input returns the existing suggestion" do
    hash = TransactionAnnotationSuggestion.input_hash_for(:hint, "corer")
    existing = @entry.annotation_suggestions.create!(family: @family, source: "hint", status: "ready", input_hash: hash)
    ActiveRecord::Validations::UniquenessValidator.any_instance.stubs(:validate_each)
    TransactionAnnotationSuggestion.stubs(:find_by).returns(nil)
    @provider.expects(:suggest_transaction_annotation).never

    assert_equal existing, suggester.suggest_from_hint(@entry, "corer")
  end

  test "a requested suggestion is claimed first, so a concurrent request does not call the LLM" do
    second = suggester
    entry = @entry
    response = success(annotation(name: "Corer"))
    concurrent = nil
    calls = 0
    provider = Object.new
    provider.define_singleton_method(:suggest_transaction_annotation) do |**|
      calls += 1
      concurrent = second.request_suggestion(entry, hint: "corer")
      response
    end
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    first = suggester.request_suggestion(@entry, hint: "corer")

    assert_equal 1, calls
    assert_equal first, concurrent
    assert concurrent.pending?
    assert first.ready?
  end

  test "a requested suggestion reuses a stored result and retries a failed one only when asked" do
    stub_annotation(annotation(name: "Corer"))
    ready = suggester.request_suggestion(@entry, hint: "corer")
    assert_equal ready, suggester.request_suggestion(@entry, hint: " Corer ")

    @provider.unstub(:suggest_transaction_annotation)
    @provider.expects(:suggest_transaction_annotation).never
    ready.update!(status: "failed", error: "boom")

    assert suggester.request_suggestion(@entry, hint: "corer", retry_failed: false).failed?

    @provider.unstub(:suggest_transaction_annotation)
    stub_annotation(annotation(name: "Corer"))
    assert suggester.request_suggestion(@entry, hint: "corer").ready?
  end

  test "sends redacted, truncated receipt text and the hint wins in one call" do
    link = receipt_links(:linked_one)
    entry = link.transaction_record.entry
    ocr = "Starbucks DE89 3704 0044 0532 0130 00 mail: a.b@example.com Tel. +49 351 1234567 " + ("x" * 7_000)
    Provider::Paperless.any_instance.expects(:document).with(101).returns({ "id" => 101, "content" => ocr })
    Provider::Paperless.any_instance.expects(:file).never

    @provider.expects(:suggest_transaction_annotation).with do |**args|
      assert_equal "latte", args[:hint]
      assert_operator args[:receipt_text].length, :<=, Suggester::MAX_RECEIPT_CHARS
      assert_no_match(/DE89|example\.com|1234567/, args[:receipt_text])
      assert_includes args[:receipt_text], "[redacted]"
      true
    end.returns(success(annotation))

    suggestion = suggester.suggest_from_hint(entry, "latte")

    assert suggestion.hint?
    assert_equal link, suggestion.receipt_link
  end

  test "a receipt whose total differs from the transaction is flagged and gets no split" do
    link = receipt_links(:linked_one)
    entry = link.transaction_record.entry
    link.update!(document_amount: 25, document_currency: "USD")
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "Total 25.00" })
    stub_annotation(annotation(split: [ part("A", 5, "Kitchen"), part("B", 5, "Outdoor") ]))

    payload = suggester.suggest_from_receipt(entry, link).payload

    assert payload["receipt_amount_mismatch"]
    assert_nil payload["split"]
  end

  test "a receipt total read by the model counts within the tolerance" do
    link = receipt_links(:linked_one)
    entry = link.transaction_record.entry
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "Total 10.40" })
    stub_annotation(annotation(receipt_total: 10.4))

    assert_not suggester.suggest_from_receipt(entry, link).payload["receipt_amount_mismatch"]
  end

  test "receipt choice prefers the linked receipt, then a clear-cut suggestion" do
    transaction = @entry.transaction
    connection = paperless_connections(:one)
    top = transaction.receipt_links.create!(paperless_connection: connection, document_id: 1, status: "suggested", score: 0.8)
    transaction.receipt_links.create!(paperless_connection: connection, document_id: 2, status: "suggested", score: 0.5)

    assert_equal top, Suggester.receipt_choice(transaction).link

    close = transaction.receipt_links.create!(paperless_connection: connection, document_id: 3, status: "suggested", score: 0.75)
    choice = Suggester.receipt_choice(transaction)
    assert_nil choice.link
    assert_equal [ top, close ], choice.candidates

    linked = transaction.receipt_links.create!(paperless_connection: connection, document_id: 4, status: "linked", score: 0.1)
    assert_equal linked, Suggester.receipt_choice(transaction).link
  end

  test "redacts IBANs, card numbers, emails and phone numbers" do
    text = "IBAN DE89 3704 0044 0532 0130 00\nCard 4111 1111 1111 1111\nshop@example.de\nTel: 0351 / 123 456\nTotal 12,99"

    redacted = Suggester.redact(text)

    assert_equal "IBAN [redacted]\nCard [redacted]\n[redacted]\nTel: [redacted]\nTotal 12,99", redacted
  end

  test "learned suggestion uses the usual category for the exact name without an LLM call" do
    create_transaction(name: "AMAZON MKTPL 123", category: @kitchen)
    @provider.expects(:suggest_transaction_annotation).never

    suggestion = suggester.learned_suggestion(@entry)

    assert suggestion.learned?
    assert suggestion.ready?
    assert_equal @kitchen.id, suggestion.payload["category_id"]
  end

  test "learned suggestion proposes nothing for a category a rule set" do
    create_transaction(name: "AMAZON MKTPL 123", category: @outdoor)
    @entry.transaction.enrich_attribute(:category_id, @kitchen.id, source: "rule")

    assert_nil suggester.learned_suggestion(@entry)
    assert_not @entry.annotation_suggestions.where(source: "learned").exists?
  end

  test "learned suggestion falls back to Bayes and is nil without an answer" do
    Family::BayesCategorizer.any_instance.stubs(:classify).returns([ @outdoor.id, 0.9 ])
    assert_equal @outdoor.id, suggester.learned_suggestion(@entry).payload["category_id"]

    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)
    assert_nil suggester.learned_suggestion(create_transaction(name: "Unknown shop"))
  end

  private
    def suggester
      Suggester.new(@family, user: @user)
    end

    def stub_annotation(result)
      @provider.stubs(:suggest_transaction_annotation).returns(success(result))
    end

    def success(data)
      Provider::Response.new(success?: true, data: data, error: nil)
    end

    def annotation(**attributes)
      Annotation.new(**{
        name: nil, merchant_name: nil, category_name: nil, tag_names: [], notes: nil,
        receipt_total: nil, split: nil, confidence: 0.8, rationale: nil
      }.merge(attributes))
    end

    def proposal(conditions:, actions:)
      Provider::LlmConcept::RuleProposal.new(conditions: conditions, actions: actions)
    end

    def condition(field, operator, value)
      { "field" => field, "operator" => operator, "value" => value }
    end

    def action(field, value)
      { "field" => field, "value" => value }
    end

    def part(name, amount, category_name)
      Part.new(name: name, amount: amount, category_name: category_name, tag_names: [], notes: nil)
    end
end
