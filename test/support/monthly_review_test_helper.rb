# Shared setup for the monthly review card tests: an October 2026 review for
# the family admin with preview features on, transactions in it, and a
# stubbed LLM provider that never reaches the network.
module MonthlyReviewTestHelper
  include EntriesTestHelper

  REVIEW_DATE = Date.new(2026, 10, 15)

  def setup_monthly_review
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @family = @user.family
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }
    @connection = paperless_connections(:one)
    @review = MonthlyReview.for(@family, REVIEW_DATE)
  end

  def review_transaction(name, day: 5, amount: 20, **attributes)
    create_transaction(account: @account, date: Date.new(2026, 10, day), name: name, amount: amount, **attributes)
  end

  def link_receipt(entry, document_id:, status: "linked", score: 0.9, title: "Receipt #{document_id}")
    entry.transaction.receipt_links.create!(
      paperless_connection: @connection, document_id: document_id, status: status, score: score, document_title: title
    )
  end

  def stub_llm(name: "Coffee beans", category: nil, notes: nil, times: 1)
    provider = mock("llm")
    result = Provider::LlmConcept::TransactionAnnotation.new(
      name: name, merchant_name: nil, category_name: category&.name, tag_names: [], notes: notes,
      receipt_total: nil, split: nil, confidence: 0.9, rationale: "From the receipt"
    )
    provider.expects(:suggest_transaction_annotation).times(times).returns(Provider::Response.new(success?: true, data: result, error: nil))
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider
  end

  def forbid_llm
    provider = mock("llm")
    provider.expects(:suggest_transaction_annotation).never
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
  end

  def ready_suggestion(entry, source: "receipt", receipt_link: nil, status: "ready", hint: nil, **payload)
    TransactionAnnotationSuggestion.create!(
      entry: entry, family: @family, source: source, status: status, receipt_link: receipt_link, hint_text: hint,
      input_hash: Transaction::AnnotationSuggester.input_hash(source.to_sym, receipt_link: receipt_link, hint: hint),
      payload: { "confidence" => 0.9 }.merge(payload.stringify_keys)
    )
  end
end
