require "application_system_test_case"

# Steps through three review cards with the keyboard only: accept a receipt
# proposal, go back and undo it, accept it again, skip a card without a
# proposal and accept the last one, which ends on the month's summary. The
# receipt shows as its document; `t` switches to its text.
class MonthlyReviewCardTest < ApplicationSystemTestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @user.update!(show_ai_sidebar: false)
    @category = categories(:food_and_drink)

    @coffee = review_transaction("CARD 4711 COFFEE", day: 3, amount: 4.8)
    @receipt = link_receipt(@coffee, document_id: 11, title: "Kassenbon Coffee")
    ready_suggestion(@coffee, receipt_link: @receipt, name: "Flat white", category_id: @category.id, new_merchant_name: "Bean Bar")
    @plain = review_transaction("Unknown shop", day: 4)
    @bakery = review_transaction("Bakery", day: 6)

    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => "BEAN BAR\nFlat white 4,80\nSUMME EUR 4,80" })
    Provider::Paperless.any_instance.stubs(:file).returns([ PIXEL_PNG, "image/png" ])
    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)
    forbid_llm

    sign_in @user
  end

  test "steps through three cards with the keyboard, including undo" do
    visit monthly_review_card_path(@review)
    assert_card @coffee, state: "proposal"
    send_keys "t"
    assert_text "BEAN BAR"
    assert_field_rows

    # 3 switches the category off: only the name and the new merchant apply.
    send_keys "3"
    send_keys :enter
    assert_card @plain, state: "empty"
    assert_equal "Flat white", @coffee.reload.name
    assert_nil @coffee.transaction.category
    assert_equal "Bean Bar", @coffee.transaction.merchant.name

    # The plain card proposes nothing, yet all five rows are there.
    assert_field_rows
    %w[name merchant category tags notes].each do |field|
      assert_selector "[data-review-field-row='#{field}'][data-status='unchanged']"
    end

    send_keys [ :alt, :arrow_left ]
    assert_card @coffee, state: "reviewed"
    send_keys "u"
    assert_card @coffee, state: "proposal"
    assert_equal "CARD 4711 COFFEE", @coffee.reload.name
    assert_not @coffee.reviewed?

    send_keys :enter
    assert_card @plain, state: "empty"
    assert_equal @category, @coffee.reload.transaction.category

    send_keys :escape
    assert_card @bakery, state: "empty"
    assert_not @plain.reload.reviewed?

    send_keys :enter
    assert_current_path monthly_review_path(@review, focus: "note")
    assert_selector "h1", exact_text: "October 2026"
    assert @bakery.reload.reviewed?
    assert_equal "monthly_review[notes]", evaluate_script("document.activeElement.name")
    assert_selector "[data-review-entry-id='#{@plain.id}']"
  end

  test "edit mode starts with the proposal, its summary does not accept, and undo restores" do
    long_receipt = ([ "BEAN BAR" ] + (1..80).map { |line| "Line #{line} 0,10" }).join("\n")
    Provider::Paperless.any_instance.stubs(:document).returns({ "content" => long_receipt })

    visit monthly_review_card_path(@review)
    assert_card @coffee, state: "proposal"
    send_keys "t"
    assert_text "Line 1 0,10"

    summary = find("[data-review-card-target='edit'] summary")
    summary.send_keys(:enter)
    assert_selector "[data-review-card-target='edit'][open]"
    assert_card @coffee, state: "proposal"

    name = find_field("entry[name]")
    assert_equal "Flat white", name.value

    # Shift+Down scrolls the receipt even from inside the edit form.
    name.send_keys([ :shift, :arrow_down ])
    assert receipt_scrolled?, "expected the receipt text to scroll"

    name.fill_in(with: "Flat white large")
    name.send_keys(:enter)
    assert_card @plain, state: "empty"
    assert_equal "Flat white large", @coffee.reload.name

    send_keys [ :alt, :arrow_left ]
    assert_card @coffee, state: "reviewed"
    send_keys "u"
    assert_card @coffee, state: "proposal"
    assert_equal "CARD 4711 COFFEE", @coffee.reload.name
    assert_not @coffee.reviewed?
  end

  test "the receipt column embeds the document and t toggles its text" do
    page.current_window.resize_to(1920, 1400)
    visit monthly_review_card_path(@review)
    assert_card @coffee, state: "proposal"

    within "aside" do
      assert_selector "[data-receipt-view='document'] iframe[src$='/paperless/documents/11/preview']"
      assert_no_text "BEAN BAR"
    end

    send_keys "t"
    within "aside" do
      assert_text "BEAN BAR"
      assert_no_selector "iframe"
    end

    send_keys "t"
    within "aside" do
      assert_selector "[data-receipt-view='document'] iframe"
      assert_no_text "BEAN BAR"
    end
  end

  test "in the card the receipt is a thumbnail that opens the full document" do
    page.current_window.resize_to(1024, 1400)
    visit monthly_review_card_path(@review)
    assert_card @coffee, state: "proposal"

    find("[data-receipt-variant='narrow'] a img[src$='/paperless/documents/11/thumbnail']").click
    within "dialog" do
      assert_selector "iframe[src$='/paperless/documents/11/preview']"
    end
  end

  test "Enter in the hint input sends the hint once" do
    calls = Concurrent::AtomicFixnum.new
    result = Provider::LlmConcept::TransactionAnnotation.new(
      name: "Corer and warmers", merchant_name: nil, category_name: nil, tag_names: [], notes: nil,
      receipt_total: nil, split: nil, confidence: 0.9, rationale: "From the hint"
    )
    provider = Object.new
    provider.define_singleton_method(:suggest_transaction_annotation) do |**|
      calls.increment
      sleep 1
      Provider::Response.new(success?: true, data: result, error: nil)
    end
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)

    visit monthly_review_card_path(@review, entry_id: @plain.id)
    assert_card @plain, state: "empty"

    send_keys "h"
    find("[data-review-card-target='hint']").send_keys("corer + warmers", :enter, :enter)

    assert_card @plain, state: "proposal"
    assert_text "Corer and warmers"
    assert_equal 1, calls.value
    assert_not @plain.reload.reviewed?
  end

  PIXEL_PNG = Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")

  private
    # Scrolling is smooth, so wait for it to move.
    def receipt_scrolled?
      Timeout.timeout(Capybara.default_max_wait_time) do
        sleep 0.1 until evaluate_script(<<~JS) > 0
          Math.max(0, ...[...document.querySelectorAll("[data-receipt-scroll]")].filter((el) => el.offsetParent).map((el) => el.scrollTop))
        JS
        true
      end
    rescue Timeout::Error
      false
    end

    def send_keys(*keys)
      find("body").send_keys(*keys)
    end

    def assert_card(entry, state:)
      assert_selector "[data-review-card-entry-id='#{entry.id}'][data-review-card-state='#{state}']"
    end

    def assert_field_rows
      assert_selector "[data-review-field-row]", count: 5
      assert_equal %w[name merchant category tags notes], all("[data-review-field-row]").map { |row| row["data-review-field-row"] }
    end
end
