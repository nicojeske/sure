require "test_helper"

class Assistant::Function::SuggestTransactionAnnotationTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @function = Assistant::Function::SuggestTransactionAnnotation.new(@user)
    @entry = review_transaction("AMAZON MKTPL 123", day: 3)
    @kitchen = @family.categories.create!(name: "Kitchen", color: "#00ff00")
  end

  test "a hint builds a proposal once and returns the stored one when repeated" do
    stub_llm(name: "Apple corer", category: @kitchen, times: 1)

    result = @function.call("id" => @entry.entryable_id, "hint" => "apple corer")
    again = @function.call("id" => @entry.entryable_id, "hint" => "  Apple corer ")

    assert_equal "proposal", result[:status]
    assert_equal "hint", result[:source]
    assert_equal "apple corer", result[:hint]
    assert_equal result[:suggestion_id], again[:suggestion_id]

    changes = result[:changes].index_by { |change| change[:field] }
    assert_equal({ field: "name", current: "AMAZON MKTPL 123", proposed: "Apple corer", selected_by_default: true, allowed: true }, changes["name"])
    assert_equal "Kitchen", changes["category"][:proposed]
    assert_not changes.key?("tags")
  end

  test "an unread receipt is read now" do
    link_receipt(@entry, document_id: 7)
    Provider::Paperless.any_instance.stubs(:document).with(7).returns({ "content" => "Apple corer 20.00" })
    stub_llm(name: "Apple corer")

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "proposal", result[:status]
    assert_equal "receipt", result[:source]
    assert_equal "Receipt 7", result[:receipt][:title]
    assert_equal "Apple corer", result[:changes].first[:proposed]
  end

  test "a receipt the background prefetch is reading is waited for, not read again" do
    link = link_receipt(@entry, document_id: 7)
    pending = ready_suggestion(@entry, receipt_link: link, status: "pending")
    forbid_llm

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "pending", result[:status]
    assert_equal pending.id, result[:suggestion_id]
    assert pending.reload.in_flight?
  end

  test "a hint already being read is waited for" do
    pending = ready_suggestion(@entry, source: "hint", hint: "apple corer", status: "pending")
    forbid_llm

    result = @function.call("id" => @entry.entryable_id, "hint" => "apple corer")

    assert_equal "pending", result[:status]
    assert_equal pending.id, result[:suggestion_id]
  end

  test "a failed read is retried" do
    link = link_receipt(@entry, document_id: 7)
    failed = ready_suggestion(@entry, receipt_link: link, status: "failed")
    Provider::Paperless.any_instance.stubs(:document).with(7).returns({ "content" => "Apple corer 20.00" })
    stub_llm(name: "Apple corer")

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "proposal", result[:status]
    assert_equal failed.id, result[:suggestion_id]
    assert failed.reload.ready?
  end

  test "without a receipt or hint the learned category is proposed without the LLM" do
    forbid_llm
    Family::BayesCategorizer.any_instance.stubs(:classify).returns([ @kitchen.id, 0.9 ])

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "proposal", result[:status]
    assert result[:learned]
    assert_equal [ "category" ], result[:changes].pluck(:field)
  end

  test "nothing to propose without a receipt, hint or history" do
    forbid_llm
    Family::BayesCategorizer.any_instance.stubs(:classify).returns(nil)

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "no_proposal", result[:status]
    assert_nil result[:suggestion_id]
  end

  test "close receipt candidates are listed for the user to pick" do
    link_receipt(@entry, document_id: 7, status: "suggested", score: 0.8)
    link_receipt(@entry, document_id: 8, status: "suggested", score: 0.75)
    forbid_llm

    result = @function.call("id" => @entry.entryable_id)

    assert_equal "receipt_choice", result[:status]
    assert_equal [ "Receipt 7", "Receipt 8" ], result[:receipt_candidates].pluck(:title)
  end

  test "a read_write share gets no rename or split" do
    member = users(:family_member)
    account_shares(:depository_shared_with_member).update!(permission: "read_write")
    ready_suggestion(@entry, source: "hint", hint: "two things", name: "Two things", category_id: @kitchen.id, split: [
      { "name" => "One", "amount" => "12.0", "category_id" => @kitchen.id, "tag_ids" => [] },
      { "name" => "Two", "amount" => "8.0", "category_id" => categories(:food_and_drink).id, "tag_ids" => [] }
    ])
    forbid_llm

    result = Assistant::Function::SuggestTransactionAnnotation.new(member).call("id" => @entry.entryable_id, "hint" => "two things")

    changes = result[:changes].index_by { |change| change[:field] }
    assert_equal false, changes["name"][:allowed]
    assert_equal true, changes["category"][:allowed]
    assert_equal 2, result[:split].size
    assert_equal false, result[:split_allowed]
  end

  test "refuses read-only shares, other families and reviewed transactions" do
    forbid_llm
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    assert_equal "not_authorized", Assistant::Function::SuggestTransactionAnnotation.new(users(:family_member)).call("id" => @entry.entryable_id, "hint" => "x")[:error]
    assert_equal "not_found", Assistant::Function::SuggestTransactionAnnotation.new(users(:empty)).call("id" => @entry.entryable_id, "hint" => "x")[:error]
    assert_equal "not_found", @function.call("id" => SecureRandom.uuid)[:error]

    @entry.mark_reviewed!(@user)
    assert_equal "already_reviewed", @function.call("id" => @entry.entryable_id, "hint" => "x")[:error]
  end
end
