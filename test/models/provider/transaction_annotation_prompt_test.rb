require "test_helper"

class Provider::TransactionAnnotationPromptTest < ActiveSupport::TestCase
  test "stored fields use the content language and the rationale the interface language" do
    rules = prompt(locale: "en", content_locale: "de").rules.squish

    assert_match(/- name: [^-]*in the language of locale "de"/, rules)
    assert_match(/- merchant_name: [^-]*in the language of locale "de"/, rules)
    assert_match(/- notes: [^-]*in the language of locale "de"/, rules)
    assert_match(/split item's name and notes are in the language of locale "de"/, rules)
    assert_match(/rationale is one short sentence in the language of locale "en"/, rules)
  end

  test "without a content language everything follows the interface language" do
    rules = prompt(locale: "fr").rules

    assert_equal [ "fr" ], rules.scan(/locale "([^"]+)"/).flatten.uniq
  end

  test "rule-set fields are kept unless the hint explicitly asks to change them" do
    rules = prompt(locale: "en", rule_set_fields: %w[category tags]).rules.squish

    assert_match(/- category_name, tag_names: set by the user's rules\. Keep them null \(\[\] for tag_names\) unless the hint explicitly asks to change them/, rules)
  end

  test "without rule-set fields the prompt says nothing about rules" do
    assert_no_match(/user's rules/, prompt(locale: "en").rules)
  end

  private
    def prompt(**options)
      Provider::TransactionAnnotationPrompt.new(
        transaction: { date: "2026-10-03", amount: "12.50", currency: "EUR", name: "BURGER" },
        receipt_text: nil, hint: nil, examples: [],
        categories: [], merchants: [], tags: [], **options
      )
    end
end
