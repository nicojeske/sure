require "test_helper"

class MonthlyReview::CardTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper
  include ActiveJob::TestHelper

  setup do
    setup_monthly_review
    @entry = review_transaction("EDEKA SAGT DANKE")
    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)
  end

  test "always has the five field rows in order, unchanged without a proposal" do
    card = card_for(@entry)

    assert_equal :empty, card.state
    assert_equal %w[name merchant category tags notes], card.fields.map(&:key)
    assert_equal [ 1, 2, 3, 4, 5 ], card.fields.map(&:number)
    assert card.fields.all? { |field| field.status == :unchanged }
  end

  test "an unread receipt starts reading in the background and the card waits for it" do
    link_receipt(@entry, document_id: 1)
    forbid_llm

    card = card_for(@entry)
    assert_equal :unread, card.state

    assert_enqueued_with(job: MonthlyReview::ReadReceiptJob) { card.read_receipt_later! }
    assert_equal :loading, card.state
    assert card.suggestion.in_flight?

    assert_no_enqueued_jobs(only: MonthlyReview::ReadReceiptJob) { card_for(@entry).read_receipt_later! }
    assert_equal :loading, card_for(@entry).state
  end

  test "a receipt run that stopped answering ends as failed, not loading" do
    link = link_receipt(@entry, document_id: 1)
    stale = ready_suggestion(@entry, receipt_link: link, status: "pending")
    stale.update_columns(updated_at: (TransactionAnnotationSuggestion::PENDING_STALE_AFTER + 1.minute).ago)
    forbid_llm

    assert_equal :failed, card_for(@entry).state
  end

  test "without an LLM provider an unread receipt shows no proposal and does not wait" do
    link_receipt(@entry, document_id: 1)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    card = card_for(@entry)

    assert_no_enqueued_jobs { card.read_receipt_later! }
    assert_equal :empty, card.state
    assert card.reading_unavailable?
  end

  test "close suggested receipts ask for a choice" do
    first = link_receipt(@entry, document_id: 1, status: "suggested", score: 0.7)
    second = link_receipt(@entry, document_id: 2, status: "suggested", score: 0.65)

    card = card_for(@entry)

    assert_equal :receipt_choice, card.state
    assert_equal [ first, second ], card.receipt_candidates
  end

  test "a picked candidate's proposal is shown" do
    link_receipt(@entry, document_id: 1, status: "suggested", score: 0.7)
    picked = link_receipt(@entry, document_id: 2, status: "suggested", score: 0.65)
    ready_suggestion(@entry, receipt_link: picked, name: "Groceries")

    card = card_for(@entry)

    assert_equal :proposal, card.state
    assert_equal picked, card.receipt_link
  end

  test "a hint proposal wins over the receipt proposal unless the URL names one" do
    link = link_receipt(@entry, document_id: 1)
    receipt = ready_suggestion(@entry, receipt_link: link, name: "From receipt")
    hint = ready_suggestion(@entry, source: "hint", receipt_link: link, hint: "milk", name: "From hint")

    assert_equal hint, card_for(@entry).suggestion
    assert_equal receipt, card_for(@entry, suggestion_id: receipt.id).suggestion
  end

  test "a proposed change is selectable and the others stay unchanged" do
    link = link_receipt(@entry, document_id: 1)
    ready_suggestion(@entry, receipt_link: link, name: "Groceries", new_merchant_name: "Edeka")

    fields = card_for(@entry).fields.index_by(&:key)

    assert fields["name"].change?
    assert fields["name"].checked
    assert_equal "Groceries", fields["name"].proposed
    assert_equal "Edeka", fields["merchant"].proposed.name
    assert_equal :unchanged, fields["category"].status
  end

  test "without a receipt or hint the learned category is proposed" do
    category = categories(:food_and_drink)
    Family::BayesCategorizer.any_instance.stubs(:classify).returns([ category.id, 0.9 ])

    card = card_for(@entry)

    assert_equal :proposal, card.state
    assert card.learned?
    assert card.fields.index_by(&:key)["category"].change?
  end

  test "a reviewed card shows what the accepted proposal applied" do
    link = link_receipt(@entry, document_id: 1)
    suggestion = ready_suggestion(@entry, receipt_link: link, name: "Groceries")
    suggestion.apply!(user: @user, fields: %w[name])

    card = card_for(@entry.reload)

    assert_equal :reviewed, card.state
    assert_equal suggestion, card.suggestion
    assert_equal 1, card.applied_change_count
    assert_equal :applied, card.fields.first.status
  end

  test "a proposed merchant or split category from another family is not shown" do
    foreign_merchant = FamilyMerchant.create!(family: families(:empty), name: "Elsewhere")
    foreign_category = families(:empty).categories.create!(name: "Foreign")
    own_category = categories(:food_and_drink)
    suggestion = ready_suggestion(@entry, source: "hint", hint: "two things", merchant_id: foreign_merchant.id, split: [
      { "name" => "One", "amount" => "12.0", "category_id" => own_category.id, "tag_ids" => [] },
      { "name" => "Two", "amount" => "8.0", "category_id" => foreign_category.id, "tag_ids" => [] }
    ])

    card = card_for(@entry, suggestion_id: suggestion.id)

    assert_nil card.fields.index_by(&:key)["merchant"].proposed
    assert_equal [ own_category, nil ], card.split_parts.map(&:category)
  end

  test "a field a rule set is rule-set and names the rule" do
    rule = run_rule(category: categories(:food_and_drink))

    card = card_for(@entry.reload)

    assert card.rule_handled?
    assert_equal %w[category], card.rule_set_fields
    assert_equal rule, card.rule_for("category")
    assert_nil card.rule_for("name")
  end

  test "a field changed after the rule set it is no longer rule-set; changing them all ends rule-handled" do
    run_rule(name: "EDEKA", category: categories(:food_and_drink))
    assert_equal %w[name category], card_for(@entry.reload).rule_set_fields

    @entry.transaction.update!(category: categories(:income))
    assert_equal %w[name], card_for(@entry.reload).rule_set_fields

    @entry.update!(name: "Edeka Markt")
    card = card_for(@entry.reload)
    assert_not card.rule_handled?
    assert_empty card.rule_set_fields
  end

  test "tags a rule set are compared as a set" do
    first = @family.tags.create!(name: "First")
    second = @family.tags.create!(name: "Second")
    @entry.transaction.update!(tag_ids: [ second.id ])
    run_rule(tags: [ first ])

    assert_equal %w[tags], card_for(@entry.reload).rule_set_fields

    @entry.transaction.update!(tag_ids: [ second.id, first.id ])
    assert_equal %w[tags], card_for(@entry.reload).rule_set_fields

    @entry.transaction.update!(tag_ids: [ first.id ])
    assert_not card_for(@entry.reload).rule_handled?
  end

  test "a rule enrichment without a rule id is rule-set without a rule" do
    merchant = @family.merchants.create!(name: "Edeka")
    @entry.transaction.enrich_attribute(:merchant_id, merchant.id, source: "rule")

    card = card_for(@entry.reload)

    assert_equal %w[merchant], card.rule_set_fields
    assert_nil card.rule_for("merchant")
    assert_nil card.rule
  end

  test "a deleted rule's field stays rule-set without a rule" do
    run_rule(category: categories(:food_and_drink)).destroy!

    card = card_for(@entry.reload)

    assert card.rule_set?("category")
    assert_nil card.rule_for("category")
  end

  test "another family's rule is not named" do
    foreign = families(:empty).rules.create!(
      name: "Foreign", resource_type: "transaction",
      actions: [ Rule::Action.new(action_type: "set_transaction_name", value: "x") ]
    )
    Rule::Provenance.set(rule_id: foreign.id) { @entry.enrich_attribute(:name, "Edeka", source: "rule") }

    card = card_for(@entry.reload)

    assert card.rule_set?("name")
    assert_nil card.rule_for("name")
  end

  test "an entry of an active bill shows the bill as context" do
    bill = bill_series(name: "EDEKA SAGT DANKE", amount: 20, status: "active")

    suggestion = card_for(@entry).bill_suggestion

    assert_equal bill, suggestion.series
    assert suggestion.active?
    assert_not suggestion.suggested?
  end

  test "an entry of a suggested series offers it as a bill" do
    detected = bill_series(name: "EDEKA SAGT DANKE", amount: 20, status: "suggested")

    suggestion = card_for(@entry).bill_suggestion

    assert_equal detected, suggestion.series
    assert suggestion.suggested?
  end

  test "no bill suggestion without a series covering the entry, or for a paused one" do
    bill_series(name: "Somewhere else", amount: 20, status: "active")
    assert_nil card_for(@entry).bill_suggestion

    bill_series(name: "EDEKA SAGT DANKE", amount: 20, status: "paused")
    assert_nil card_for(@entry).bill_suggestion
  end

  test "a merchant reviewed the same way in several months suggests a rule on it" do
    eon = @family.merchants.create!(name: "EON")
    power = @family.categories.create!(name: "Strom")
    @entry.transaction.update!(merchant: eon)
    reviewed_history("EON Abschlag", merchant: eon, category: power, dates: [ Date.new(2026, 8, 3), Date.new(2026, 9, 3), Date.new(2026, 9, 20) ])

    suggestion = card_for(@entry).rule_suggestion

    assert_equal [ { condition_type: "transaction_merchant", operator: "=", value: eon.id } ], suggestion.conditions
    assert_equal [
      { action_type: "set_transaction_category", value: power.id },
      { action_type: "set_transaction_name", value: "EON Abschlag" }
    ], suggestion.actions
    assert_equal "EON → Strom, 3× in 2 months", suggestion.summary
    assert_equal "merchant:#{eon.id}", suggestion.pattern_key
    assert_equal [ :rule ], card_for(@entry).strip_suggestions.keys
  end

  test "no rule suggestion with fewer than three matches or all in one month" do
    eon = @family.merchants.create!(name: "EON")
    @entry.transaction.update!(merchant: eon)
    reviewed_history("EON", merchant: eon, category: categories(:food_and_drink), dates: [ Date.new(2026, 8, 3), Date.new(2026, 9, 3) ])

    assert_nil card_for(@entry).rule_suggestion

    vattenfall = @family.merchants.create!(name: "Vattenfall")
    @entry.transaction.update!(merchant: vattenfall)
    reviewed_history("Vattenfall", merchant: vattenfall, category: categories(:food_and_drink), dates: [ Date.new(2026, 9, 1), Date.new(2026, 9, 10), Date.new(2026, 9, 28) ])

    assert_nil card_for(@entry).rule_suggestion
  end

  test "no rule suggestion when the matches differ in category" do
    eon = @family.merchants.create!(name: "EON")
    @entry.transaction.update!(merchant: eon)
    reviewed_history("EON", merchant: eon, category: categories(:food_and_drink), dates: [ Date.new(2026, 8, 3), Date.new(2026, 9, 3) ])
    reviewed_history("EON", merchant: eon, category: categories(:one), dates: [ Date.new(2026, 9, 20) ])

    assert_nil card_for(@entry).rule_suggestion
  end

  test "without a merchant the rule matches the raw name's stem and sets what all matches share" do
    eon = @family.merchants.create!(name: "EON")
    power = @family.categories.create!(name: "Strom")
    entry = review_transaction("EON ENERGIE 1023 ABSCHLAG")
    [ Date.new(2026, 7, 3), Date.new(2026, 8, 3), Date.new(2026, 9, 3) ].each do |date|
      renamed = reviewed_history("EON Strom", merchant: eon, category: power, dates: [ date ]).first
      renamed.transaction.update!(extra: { "original_name" => "EON  Energie #{date.strftime('%m%y')} ABSCHLAG" })
    end
    reviewed_history("EON ENERGIE NACHZAHLUNG", category: categories(:one), dates: [ Date.new(2026, 9, 9) ])

    suggestion = card_for(entry).rule_suggestion

    assert_equal [ { condition_type: "transaction_name", operator: "like", value: "EON ENERGIE" } ], suggestion.conditions
    assert_equal [
      { action_type: "set_transaction_category", value: power.id },
      { action_type: "set_transaction_merchant", value: eon.id },
      { action_type: "set_transaction_name", value: "EON Strom" }
    ], suggestion.actions
    assert_equal "EON ENERGIE → Strom, 3× in 3 months", suggestion.summary
    assert_equal "name:eon energie", suggestion.pattern_key
  end

  test "tags are set only when every match has the same ones" do
    eon = @family.merchants.create!(name: "EON")
    @entry.transaction.update!(merchant: eon)
    first, second = tags(:one), tags(:two)
    reviewed_history("EON", merchant: eon, category: categories(:food_and_drink), tags: [ first, second ], dates: [ Date.new(2026, 8, 3), Date.new(2026, 9, 3) ])
    reviewed_history("EON", merchant: eon, category: categories(:food_and_drink), tags: [ second, first ], dates: [ Date.new(2026, 9, 20) ])

    assert_includes card_for(@entry).rule_suggestion.actions, { action_type: "set_transaction_tags", value: [ first.id, second.id ].sort }

    reviewed_history("EON", merchant: eon, category: categories(:food_and_drink), tags: [ first ], dates: [ Date.new(2026, 9, 25) ])

    assert_equal %w[set_transaction_category set_transaction_name], card_for(@entry).rule_suggestion.actions.map { |action| action[:action_type] }
  end

  test "a rule-handled transaction gets no rule suggestion" do
    reviewed_history("EDEKA SAGT DANKE", category: categories(:food_and_drink), dates: [ Date.new(2026, 8, 3), Date.new(2026, 9, 3), Date.new(2026, 9, 20) ])
    assert card_for(@entry).rule_suggestion

    run_rule(category: categories(:food_and_drink))

    assert_nil card_for(@entry.reload).rule_suggestion
  end

  private
    # Reviewed transactions before the review month, one per date.
    def reviewed_history(name, dates:, category: nil, merchant: nil, tags: [])
      dates.map do |date|
        create_transaction(account: @account, date: date, name: name, amount: 85, category: category, merchant: merchant, tags: tags).tap do |entry|
          entry.update_columns(reviewed_at: date.to_time)
        end
      end
    end

    def card_for(entry, suggestion_id: nil)
      MonthlyReview::Card.new(@review, entry, user: @user, suggestion_id: suggestion_id)
    end

    def run_rule(name: nil, category: nil, tags: nil)
      actions = []
      actions << Rule::Action.new(action_type: "set_transaction_name", value: name) if name
      actions << Rule::Action.new(action_type: "set_transaction_category", value: category.id) if category
      actions << Rule::Action.new(action_type: "set_transaction_tags", value: tags.map(&:id)) if tags
      rule = @family.rules.create!(
        name: "EDEKA", resource_type: "transaction", active: true,
        conditions: [ Rule::Condition.new(condition_type: "transaction_name", operator: "like", value: "EDEKA") ],
        actions: actions
      )
      Rule::Runner.new(@family, rules: [ rule ], execution_type: "manual").run
      rule
    end

    def bill_series(name:, amount:, status:)
      @family.recurring_transactions.create!(
        account: @account, name: name, amount: amount, currency: "USD", expected_day_of_month: 5,
        last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current,
        status: status, occurrence_count: 3
      )
    end
end
