require "test_helper"

class Assistant::Function::ApplyTransactionAnnotationTest < ActiveSupport::TestCase
  include MonthlyReviewTestHelper

  setup do
    setup_monthly_review
    @function = Assistant::Function::ApplyTransactionAnnotation.new(@user)
    @kitchen = @family.categories.create!(name: "Kitchen", color: "#00ff00")
    @outdoor = @family.categories.create!(name: "Outdoor", color: "#0000ff")
    @entry = review_transaction("AMAZON MKTPL 123", day: 3, notes: "keep me")
    @suggestion = ready_suggestion(
      @entry, source: "hint", hint: "corer and hand warmer",
      name: "Corer and hand warmer", category_id: @kitchen.id, notes: "Corer, hand warmer",
      split: [
        { "name" => "Corer", "amount" => "12.0", "category_id" => @kitchen.id, "tag_ids" => [], "notes" => nil },
        { "name" => "Hand warmer", "amount" => "8.0", "category_id" => @outdoor.id, "tag_ids" => [], "notes" => nil }
      ]
    )
  end

  test "applies the default selection and marks the transaction reviewed" do
    @entry.lock_attr!(:notes)

    result = @function.call("suggestion_id" => @suggestion.id)

    assert result[:success]
    assert_equal %w[name category], result[:applied_fields]
    assert result[:split]
    assert_equal "Corer and hand warmer", result[:transaction][:name]
    assert_equal "keep me", result[:transaction][:notes]
    assert_equal [ "Corer", "Hand warmer" ], result[:transaction][:parts].pluck(:name)

    @entry.reload
    assert @entry.reviewed?
    assert_equal @user, @entry.reviewed_by
    assert @entry.split_parent?
    assert @entry.child_entries.all?(&:reviewed?)
    assert @suggestion.reload.applied?
  end

  test "applies only the chosen fields and no split" do
    result = @function.call("suggestion_id" => @suggestion.id, "fields" => [ "category", "tags" ], "split" => false)

    assert result[:success]
    assert_equal [ "category" ], result[:applied_fields]
    assert_not result[:split]

    @entry.reload
    assert_equal "AMAZON MKTPL 123", @entry.name
    assert_equal @kitchen, @entry.transaction.category
    assert_not @entry.split_parent?
    assert @entry.reviewed?
  end

  test "an empty field list only marks the transaction reviewed" do
    result = @function.call("suggestion_id" => @suggestion.id, "fields" => [], "split" => false)

    assert result[:success]
    assert_empty result[:applied_fields]
    assert_equal "AMAZON MKTPL 123", @entry.reload.name
    assert @entry.reviewed?
  end

  test "a read_write share may annotate but neither rename nor split" do
    account_shares(:depository_shared_with_member).update!(permission: "read_write")
    function = Assistant::Function::ApplyTransactionAnnotation.new(users(:family_member))

    assert_equal "field_not_allowed", function.call("suggestion_id" => @suggestion.id, "fields" => [ "name" ])[:error]
    assert_equal "split_not_allowed", function.call("suggestion_id" => @suggestion.id, "split" => true)[:error]
    assert_not @entry.reload.reviewed?

    result = function.call("suggestion_id" => @suggestion.id)

    assert result[:success]
    assert_equal %w[category notes], result[:applied_fields].sort
    assert_not result[:split]
    assert_equal "AMAZON MKTPL 123", @entry.reload.name
  end

  test "a read-only share can't apply" do
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    result = Assistant::Function::ApplyTransactionAnnotation.new(users(:family_member)).call("suggestion_id" => @suggestion.id)

    assert_equal "not_authorized", result[:error]
    assert_not @entry.reload.reviewed?
  end

  test "another family's proposal is not found" do
    result = Assistant::Function::ApplyTransactionAnnotation.new(users(:empty)).call("suggestion_id" => @suggestion.id)

    assert_equal "not_found", result[:error]
    assert_not @entry.reload.reviewed?
    assert_equal "not_found", @function.call("suggestion_id" => "not-a-uuid")[:error]
  end

  test "refuses unknown fields, a missing split and a second apply" do
    assert_equal "invalid_fields", @function.call("suggestion_id" => @suggestion.id, "fields" => [ "amount" ])[:error]

    no_split = ready_suggestion(@entry, source: "hint", hint: "corer", category_id: @kitchen.id)
    assert_equal "split_not_allowed", @function.call("suggestion_id" => no_split.id, "split" => true)[:error]

    assert @function.call("suggestion_id" => @suggestion.id, "split" => false)[:success]
    assert_equal "already_reviewed", @function.call("suggestion_id" => no_split.id)[:error]
  end
end
