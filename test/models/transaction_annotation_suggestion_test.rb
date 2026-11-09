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

  test "claim_for creates a pending row once and then refuses while it is in flight or done" do
    entry = create_transaction
    attributes = { family: entry.account.family, source: "receipt" }

    claimed = TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", **attributes)
    assert claimed.pending?
    assert claimed.in_flight?
    assert_nil TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", **attributes)

    claimed.update!(status: "ready")
    assert_nil TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", retry_failed: true, **attributes)
  end

  test "claim_for takes over a stale pending row" do
    entry = create_transaction
    stale = entry.annotation_suggestions.create!(family: entry.account.family, source: "receipt", status: "pending", input_hash: "abc")
    stale.update_columns(updated_at: (TransactionAnnotationSuggestion::PENDING_STALE_AFTER + 1.minute).ago)
    assert_not stale.reload.in_flight?

    claimed = TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", family: entry.account.family, source: "receipt")

    assert_equal stale, claimed
    assert claimed.in_flight?
    assert_nil TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", family: entry.account.family, source: "receipt")
  end

  test "claim_for retries a failed row only when asked" do
    entry = create_transaction
    failed = entry.annotation_suggestions.create!(family: entry.account.family, source: "receipt", status: "failed", error: "down", input_hash: "abc")

    assert_nil TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", family: entry.account.family, source: "receipt")

    claimed = TransactionAnnotationSuggestion.claim_for(entry, input_hash: "abc", retry_failed: true, family: entry.account.family, source: "receipt")
    assert_equal failed, claimed
    assert claimed.pending?
    assert_nil claimed.error
  end
end
