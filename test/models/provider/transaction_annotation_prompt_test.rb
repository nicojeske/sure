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

  private
    def prompt(**locales)
      Provider::TransactionAnnotationPrompt.new(
        transaction: { date: "2026-10-03", amount: "12.50", currency: "EUR", name: "BURGER" },
        receipt_text: nil, hint: nil, examples: [],
        categories: [], merchants: [], tags: [], **locales
      )
    end
end
