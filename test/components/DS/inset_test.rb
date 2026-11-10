require "test_helper"

class DS::InsetTest < ViewComponent::TestCase
  test "renders an inset box around its content" do
    render_inline(DS::Inset.new) { "Reading the receipt" }

    assert_selector "div.rounded-lg.bg-container-inset.p-3.text-sm.text-secondary", text: "Reading the receipt"
    assert_no_selector "div.overflow-auto"
    assert_no_selector "[tabindex]"
  end

  test "renders a paragraph in small print" do
    render_inline(DS::Inset.new(tag: :p, text_size: :xs)) { "No text" }

    assert_selector "p.bg-container-inset.text-xs", text: "No text"
    assert_no_selector ".text-sm"
  end

  test "merges layout classes and forwards other options" do
    render_inline(DS::Inset.new(class: "flex items-center gap-3", role: "status", data: { review_state: "busy" })) { "Busy" }

    assert_selector "div.bg-container-inset.flex.items-center.gap-3[role='status'][data-review-state='busy']", text: "Busy"
  end

  test "a scrolling box can be focused and is named" do
    render_inline(DS::Inset.new(scroll_label: "Receipt text", class: "max-h-48", data: { receipt_scroll: true })) { "BEAN BAR" }

    assert_selector "div.max-h-48.overflow-auto[tabindex='0'][aria-label='Receipt text'][data-receipt-scroll]", text: "BEAN BAR"
  end

  test "refuses other tags and text sizes" do
    assert_raises(ArgumentError) { DS::Inset.new(tag: :section) }
    assert_raises(KeyError) { DS::Inset.new(text_size: :lg) }
  end
end
