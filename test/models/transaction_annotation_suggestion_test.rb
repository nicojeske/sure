require "test_helper"

class TransactionAnnotationSuggestionTest < ActiveSupport::TestCase
  include EntriesTestHelper

  test "input hash ignores whitespace and case but separates sources" do
    hash = TransactionAnnotationSuggestion.input_hash_for(:hint, "Apfelentkerner  + Handwärmer")

    assert_equal hash, TransactionAnnotationSuggestion.input_hash_for("hint", " apfelentkerner + handwärmer ")
    assert_not_equal hash, TransactionAnnotationSuggestion.input_hash_for(:receipt, "Apfelentkerner + Handwärmer")
  end

  test "one suggestion per entry and input" do
    entry = create_transaction
    attributes = { family: entry.account.family, source: "hint", input_hash: "abc" }
    entry.annotation_suggestions.create!(attributes)

    duplicate = entry.annotation_suggestions.build(attributes)

    assert_not duplicate.valid?
  end

  test "suggestions are removed with their entry" do
    entry = create_transaction
    entry.annotation_suggestions.create!(family: entry.account.family, source: "learned", input_hash: "abc")

    assert_difference "TransactionAnnotationSuggestion.count", -1 do
      entry.destroy!
    end
  end
end
