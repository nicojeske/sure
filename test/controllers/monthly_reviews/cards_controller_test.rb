require "test_helper"

class MonthlyReviews::CardsControllerTest < ActionDispatch::IntegrationTest
  include MonthlyReviewTestHelper
  include ActiveJob::TestHelper

  setup do
    setup_monthly_review
    sign_in @user
    @first = review_transaction("Coffee shop", day: 3)
    @second = review_transaction("Book store", day: 4)
    @third = review_transaction("Bakery", day: 6)
  end

  test "redirects users without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get monthly_review_card_url(@review)

    assert_redirected_to root_path
  end

  test "404s for an unknown month" do
    get monthly_review_card_url("nonsense")

    assert_response :not_found
  end

  test "opens on the first unreviewed entry and shows all five field rows" do
    @first.mark_reviewed!(@user)

    get monthly_review_card_url(@review)

    assert_response :success
    assert_select "[data-review-card-entry-id='#{@second.id}']"
    assert_select "[data-review-field-row]", 5
    %w[name merchant category tags notes].each do |field|
      assert_select "[data-review-field-row='#{field}'][data-status='unchanged']"
    end
  end

  test "opening the review starts a prefetch, a frame request does not" do
    assert_enqueued_with(job: MonthlyReview::PrefetchSuggestionsJob) do
      get monthly_review_card_url(@review)
    end

    @review.update_columns(prefetched_at: nil)
    assert_no_enqueued_jobs(only: MonthlyReview::PrefetchSuggestionsJob) do
      get monthly_review_card_url(@review, entry_id: @second.id), headers: { "Turbo-Frame" => "monthly_review_card" }
    end
  end

  test "opening a card starts reading its unread receipt and the next card's" do
    link_receipt(@first, document_id: 1)
    link_receipt(@second, document_id: 2)
    forbid_llm

    assert_enqueued_jobs 2, only: MonthlyReview::ReadReceiptJob do
      get monthly_review_card_url(@review, entry_id: @first.id), headers: { "Turbo-Frame" => "monthly_review_card" }
    end

    assert_select "[data-review-card-entry-id='#{@first.id}'][data-review-card-state='loading']"
    assert @second.annotation_suggestions.sole.in_flight?

    assert_no_enqueued_jobs(only: MonthlyReview::ReadReceiptJob) do
      get monthly_review_card_url(@review, entry_id: @first.id), headers: { "Turbo-Frame" => "monthly_review_card" }
    end
  end

  test "without an LLM provider an unread receipt says it can't be read instead of waiting" do
    link_receipt(@first, document_id: 1)
    Provider::Registry.stubs(:preferred_llm_provider).returns(nil)

    assert_no_enqueued_jobs(only: MonthlyReview::ReadReceiptJob) do
      get monthly_review_card_url(@review, entry_id: @first.id)
    end

    assert_select "[data-review-card-state='empty']"
    assert_select "p", text: I18n.t("monthly_reviews.cards.state.unavailable")
  end

  test "shows the requested entry and 404s for an entry outside the month" do
    get monthly_review_card_url(@review, entry_id: @third.id)
    assert_select "[data-review-card-entry-id='#{@third.id}']"

    other_month = create_transaction(account: @account, date: Date.new(2026, 9, 30), name: "September")
    get monthly_review_card_url(@review, entry_id: other_month.id)
    assert_response :not_found
  end

  test "an in-flight suggestion shows a spinner without calling the LLM" do
    link = link_receipt(@first, document_id: 1)
    ready_suggestion(@first, receipt_link: link, status: "pending")
    forbid_llm

    get monthly_review_card_url(@review, entry_id: @first.id)

    assert_select "[data-review-card-state='loading']"
  end

  test "a ready receipt proposal shows the change with its checkbox" do
    link = link_receipt(@first, document_id: 1)
    ready_suggestion(@first, receipt_link: link, name: "Espresso beans")

    get monthly_review_card_url(@review, entry_id: @first.id)

    assert_select "[data-review-card-state='proposal']"
    assert_select "[data-review-field-row='name'][data-status='change'] input[type=checkbox][name='fields[]'][value='name']"
    assert_select "[data-review-field-row='category'][data-status='unchanged'] input[type=checkbox]", 0
    assert_select "[data-review-field-row]", 5
  end

  test "a linked PDF receipt shows as the document in the receipt column and as a thumbnail in the card" do
    link = link_receipt(@first, document_id: 7, mime_type: "application/pdf")
    ready_suggestion(@first, receipt_link: link, name: "Espresso beans")

    get monthly_review_card_url(@review, entry_id: @first.id)

    assert_select "[data-receipt-variant='wide'] [data-receipt-view='document'] iframe[src='#{preview_paperless_document_path(7)}']"
    assert_select "[data-receipt-variant='wide'] [data-receipt-view='document'] img", 0
    assert_select "[data-receipt-variant='narrow'] [data-receipt-view='document'] a[href='#{paperless_document_path(7)}'][data-turbo-frame='modal'] img[src='#{thumbnail_paperless_document_path(7)}']"
    assert_select "[data-receipt-variant='narrow'] iframe", 0
    %w[wide narrow].each do |variant|
      assert_select "[data-receipt-variant='#{variant}'] [data-receipt-view='text'] turbo-frame[src*='receipt_text']"
    end
  end

  test "a linked image receipt shows as an image in the receipt column" do
    link = link_receipt(@first, document_id: 8, mime_type: "image/jpeg")
    ready_suggestion(@first, receipt_link: link, name: "Espresso beans")

    get monthly_review_card_url(@review, entry_id: @first.id)

    assert_select "[data-receipt-variant='wide'] [data-receipt-view='document'] img[src='#{preview_paperless_document_path(8)}']"
    assert_select "[data-receipt-variant='wide'] [data-receipt-view='document'] iframe", 0
  end

  test "opening a review with nothing left goes to the summary" do
    [ @first, @second, @third ].each { |entry| entry.mark_reviewed!(@user) }

    get monthly_review_card_url(@review)

    assert_redirected_to monthly_review_path(@review, focus: "note")
  end

  test "the breadcrumbs lead back to the month's summary and the overview" do
    get monthly_review_card_url(@review)

    assert_select "[data-breadcrumbs] a[href=?]", monthly_reviews_path, text: I18n.t("breadcrumbs.monthly_reviews")
    assert_select "[data-breadcrumbs] a[href=?]", monthly_review_path(@review), text: "October 2026"
    assert_select "[data-breadcrumbs] > span:last-child", text: I18n.t("breadcrumbs.monthly_review_cards")
  end

  test "accept applies the selected fields, marks reviewed and goes to the next card" do
    link = link_receipt(@first, document_id: 1)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans", notes: "250 g")

    patch monthly_review_card_url(@review), params: {
      decision: "accept", entry_id: @first.id, suggestion_id: suggestion.id, fields: %w[name]
    }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    @first.reload
    assert_equal "Espresso beans", @first.name
    assert_nil @first.notes
    assert @first.reviewed?
    assert suggestion.reload.applied?
  end

  test "accept without a proposal only marks reviewed" do
    patch monthly_review_card_url(@review), params: { decision: "accept", entry_id: @first.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    assert @first.reload.reviewed?
  end

  test "accept on the last card ends on the summary with the note focused" do
    @first.mark_reviewed!(@user)
    @second.mark_reviewed!(@user)

    patch monthly_review_card_url(@review, include_transfers: "1"), params: { decision: "accept", entry_id: @third.id }

    assert_redirected_to monthly_review_path(@review, focus: "note", include_transfers: "1")
    follow_redirect!
    assert_select "textarea[name='monthly_review[notes]'][autofocus]"
  end

  test "accept and reviewed_only on a reviewed card only move on" do
    link = link_receipt(@first, document_id: 1)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans")
    suggestion.apply!(user: @user, fields: %w[name])
    reviewed_at = @first.reload.reviewed_at

    travel 1.minute do
      %w[accept reviewed_only].each do |decision|
        patch monthly_review_card_url(@review), params: { decision: decision, entry_id: @first.id, suggestion_id: suggestion.id, fields: %w[name] }
        assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
      end
    end

    assert_equal reviewed_at, @first.reload.reviewed_at
    assert_equal suggestion, TransactionAnnotationSuggestion.applied_in_review_of(@first)

    patch monthly_review_card_url(@review), params: { decision: "undo", entry_id: @first.id }
    assert_equal "Coffee shop", @first.reload.name
    assert_not @first.reviewed?
  end

  test "reviewed_only marks reviewed without applying the proposal" do
    link = link_receipt(@first, document_id: 1)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans")

    patch monthly_review_card_url(@review), params: {
      decision: "reviewed_only", entry_id: @first.id, suggestion_id: suggestion.id, fields: %w[name]
    }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    assert @first.reload.reviewed?
    assert_equal "Coffee shop", @first.name
    assert suggestion.reload.ready?
  end

  test "skip moves on without marking reviewed" do
    patch monthly_review_card_url(@review), params: { decision: "skip", entry_id: @first.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    assert_not @first.reload.reviewed?
  end

  test "back goes to the previous entry, reviewed or not" do
    @first.mark_reviewed!(@user)

    patch monthly_review_card_url(@review), params: { decision: "back", entry_id: @second.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id)
  end

  test "undo reverts the accepted proposal and stays on the card" do
    link = link_receipt(@first, document_id: 1)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans")
    suggestion.apply!(user: @user, fields: %w[name])

    patch monthly_review_card_url(@review), params: { decision: "undo", entry_id: @first.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id)
    @first.reload
    assert_equal "Coffee shop", @first.name
    assert_not @first.reviewed?
    assert suggestion.reload.reverted?
  end

  test "accepting a split reviews its parts, and undo on a part reverts the split" do
    household = @family.categories.create!(name: "Household")
    suggestion = ready_suggestion(@first, source: "hint", hint: "beans 12 + mug 8", split: [
      { "name" => "Beans", "amount" => "12.0", "category_id" => categories(:food_and_drink).id, "tag_ids" => [] },
      { "name" => "Mug", "amount" => "8.0", "category_id" => household.id, "tag_ids" => [] }
    ])

    patch monthly_review_card_url(@review), params: { decision: "accept", entry_id: @first.id, suggestion_id: suggestion.id, split: "1" }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    part = @first.reload.child_entries.first
    assert part.reviewed?

    patch monthly_review_card_url(@review), params: { decision: "undo", entry_id: part.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id)
    assert_not @first.reload.split_parent?
    assert_not @first.reviewed?
  end

  test "undo of a card marked reviewed without a proposal clears reviewed" do
    @first.mark_reviewed!(@user)

    patch monthly_review_card_url(@review), params: { decision: "undo", entry_id: @first.id }

    assert_not @first.reload.reviewed?
  end

  test "suggest reads the receipt on request and shows the proposal" do
    link = link_receipt(@first, document_id: 7)
    Provider::Paperless.any_instance.stubs(:document).with(7).returns({ "content" => "Espresso 9.99" })
    stub_llm(name: "Espresso beans")

    patch monthly_review_card_url(@review), params: { decision: "suggest", entry_id: @first.id, receipt_link_id: link.id }

    suggestion = @first.annotation_suggestions.sole
    assert suggestion.ready?
    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id, suggestion_id: suggestion.id)
  end

  test "suggest does not call the LLM while the same receipt is in flight" do
    link = link_receipt(@first, document_id: 7)
    pending = ready_suggestion(@first, receipt_link: link, status: "pending")
    forbid_llm

    patch monthly_review_card_url(@review), params: { decision: "suggest", entry_id: @first.id, receipt_link_id: link.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id, suggestion_id: pending.id)
  end

  test "edit saves the typed values as a user edit and goes next" do
    category = categories(:food_and_drink)

    patch monthly_review_card_url(@review), params: {
      decision: "edit", entry_id: @first.id,
      entry: { name: "Flat white", notes: "with Anna", entryable_attributes: { category_id: category.id } }
    }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id)
    @first.reload
    assert_equal "Flat white", @first.name
    assert_equal "with Anna", @first.notes
    assert_equal category, @first.transaction.category
    assert @first.locked?(:name)
    assert @first.reviewed?
  end

  test "edit mode starts with the proposed values" do
    link = link_receipt(@first, document_id: 1)
    category = categories(:food_and_drink)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans", category_id: category.id)

    get monthly_review_card_url(@review, entry_id: @first.id)

    assert_select "[data-review-card-target='edit']" do
      assert_select "input[name='suggestion_id'][value='#{suggestion.id}']"
      assert_select "input[name='entry[name]'][value='Espresso beans']"
      assert_select "input[name='entry[entryable_attributes][category_id]'][value='#{category.id}']"
    end
  end

  test "undo after edit restores the previous values" do
    link = link_receipt(@first, document_id: 1)
    suggestion = ready_suggestion(@first, receipt_link: link, name: "Espresso beans")
    category = categories(:food_and_drink)

    patch monthly_review_card_url(@review), params: {
      decision: "edit", entry_id: @first.id, suggestion_id: suggestion.id,
      entry: { name: "Flat white", notes: "with Anna", entryable_attributes: { category_id: category.id } }
    }
    assert_equal "Flat white", @first.reload.name
    assert suggestion.reload.ready?

    get monthly_review_card_url(@review, entry_id: @first.id)
    assert_select "[data-review-card-state='reviewed']"

    patch monthly_review_card_url(@review), params: { decision: "undo", entry_id: @first.id }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @first.id)
    @first.reload
    assert_equal "Coffee shop", @first.name
    assert_nil @first.notes
    assert_nil @first.transaction.category
    assert_not @first.locked?(:name)
    assert_not @first.reviewed?

    follow_redirect!
    assert_select "[data-review-card-state='proposal']"
    assert_select "input[name='suggestion_id'][value='#{suggestion.id}']"
  end

  test "keeps the transfers toggle in the redirect" do
    patch monthly_review_card_url(@review), params: { decision: "skip", entry_id: @first.id, include_transfers: "1" }

    assert_redirected_to monthly_review_card_path(@review, entry_id: @second.id, include_transfers: "1")
  end

  test "confirming a suggested bill from the card makes it a bill and refreshes the card" do
    series = @family.recurring_transactions.create!(
      account: @account, name: "Coffee shop", amount: 20, currency: "USD", expected_day_of_month: 3,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current, status: "suggested", occurrence_count: 3
    )
    card_url = monthly_review_card_url(@review, entry_id: @first.id)
    frame = { "Turbo-Frame" => "monthly_review_card" }

    get card_url, headers: frame
    assert_select "[data-review-suggestion='bill'][data-review-suggestion-action='accept']"
    assert_select "form[action='#{confirm_recurring_transaction_path(series)}']"
    assert_select "form[action='#{dismiss_recurring_transaction_path(series)}']"

    post confirm_recurring_transaction_url(series), headers: frame.merge("Referer" => card_url)

    assert_redirected_to card_url
    assert series.reload.active?

    follow_redirect!(headers: frame)
    assert_select "[data-review-card-entry-id='#{@first.id}']"
    assert_select "[data-review-bill='active']", text: /Coffee shop/
    assert_select "[data-review-suggestion='bill']", count: 0
  end

  test "dismissing a suggested bill from the card removes the suggestion" do
    series = @family.recurring_transactions.create!(
      account: @account, name: "Coffee shop", amount: 20, currency: "USD", expected_day_of_month: 3,
      last_occurrence_date: 1.month.ago.to_date, next_expected_date: Date.current, status: "suggested", occurrence_count: 3
    )
    card_url = monthly_review_card_url(@review, entry_id: @first.id)

    post dismiss_recurring_transaction_url(series), headers: { "Referer" => card_url }

    assert_redirected_to card_url
    assert series.reload.ended?
    follow_redirect!
    assert_select "[data-review-bill]", count: 0
    assert_select "[data-review-suggestion='bill']", count: 0
  end

  test "rejects an unknown decision" do
    patch monthly_review_card_url(@review), params: { decision: "explode", entry_id: @first.id }

    assert_response :unprocessable_entity
  end
end
