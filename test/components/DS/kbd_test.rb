require "test_helper"

class DS::KbdTest < ViewComponent::TestCase
  test "renders the key in a key cap" do
    render_inline(DS::Kbd.new(key: "Esc"))

    assert_selector "kbd.font-mono.border-secondary.bg-container-inset", exact_text: "Esc"
  end

  test "renders a number key" do
    render_inline(DS::Kbd.new(key: 3))

    assert_selector "kbd", exact_text: "3"
  end

  test "escapes the key" do
    render_inline(DS::Kbd.new(key: "<b>"))

    assert_selector "kbd", exact_text: "<b>"
    assert_no_selector "kbd b"
  end
end
