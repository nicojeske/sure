require "test_helper"

class TransactionAnnotationSuggestion::ApplierTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family
    @kitchen = @family.categories.create!(name: "Kitchen", color: "#00ff00")
    @outdoor = @family.categories.create!(name: "Outdoor", color: "#0000ff")
    @entry = create_transaction(name: "AMAZON MKTPL 123", amount: 20, notes: "keep me")
    @suggestion = @entry.annotation_suggestions.create!(
      family: @family, source: "hint", status: "ready", input_hash: "abc",
      payload: {
        "name" => "Corer and hand warmer", "notes" => "Corer, hand warmer",
        "category_id" => @kitchen.id, "new_merchant_name" => "Manufactum",
        "tag_ids" => [ tags(:one).id ],
        "split" => [
          { "name" => "Corer", "amount" => "12.0", "category_id" => @kitchen.id, "tag_ids" => [], "notes" => nil },
          { "name" => "Hand warmer", "amount" => "8.0", "category_id" => @outdoor.id, "tag_ids" => [], "notes" => nil }
        ]
      }
    )
  end

  test "fields start on when empty or set automatically, off when the user set them" do
    @entry.lock_attr!(:notes)

    selection = @suggestion.default_selection(@owner)

    assert_equal true, selection["name"]
    assert_equal true, selection["category"]
    assert_equal true, selection["merchant"]
    assert_equal true, selection["tags"]
    assert_equal false, selection["notes"]
    assert_equal true, selection["split"]
  end

  test "a category or merchant locked by automation still starts on" do
    transaction = @entry.transaction
    transaction.enrich_attribute(:category_id, @outdoor.id, source: "ai")
    transaction.lock_attr!(:category_id)
    transaction.enrich_attribute(:merchant_id, merchants(:netflix).id, source: "similar")
    transaction.lock_attr!(:merchant_id)

    selection = @suggestion.reload.default_selection(@owner)

    assert_equal true, selection["category"]
    assert_equal true, selection["merchant"]
  end

  test "a category the user changed after automation set it starts off" do
    transaction = @entry.transaction
    transaction.enrich_attribute(:category_id, @outdoor.id, source: "bayes")
    transaction.update!(category: categories(:food_and_drink))
    transaction.lock_attr!(:category_id)

    assert_equal false, @suggestion.reload.default_selection(@owner)["category"]
  end

  test "unchanged fields are not proposed" do
    @entry.update!(name: "Corer and hand warmer")

    assert_not_includes @suggestion.default_selection(@owner).keys, "name"
  end

  test "applies selected fields as a user edit and marks the entry reviewed" do
    @suggestion.apply!(user: @owner, fields: %w[name category merchant tags])

    @entry.reload
    transaction = @entry.transaction
    assert_equal "Corer and hand warmer", @entry.name
    assert_equal "keep me", @entry.notes
    assert_equal "AMAZON MKTPL 123", transaction.extra["original_name"]
    assert_equal @kitchen, transaction.category
    assert_equal "Manufactum", transaction.merchant.name
    assert_equal @family, transaction.merchant.family
    assert_equal [ tags(:one) ], transaction.tags
    assert transaction.locked?(:category_id)
    assert @entry.locked?(:name)
    assert @entry.user_modified?
    assert @entry.reviewed?
    assert_equal @owner, @entry.reviewed_by
    assert @suggestion.reload.applied?
  end

  test "keeps the first bank name when renamed again" do
    @entry.transaction.update!(extra: { "original_name" => "BANK TEXT" })

    @suggestion.apply!(user: @owner, fields: %w[name])

    assert_equal "BANK TEXT", @entry.transaction.reload.extra["original_name"]
  end

  test "apply and revert round trip with a split and a suggested receipt" do
    link = @entry.transaction.receipt_links.create!(paperless_connection: paperless_connections(:one), document_id: 9, status: "suggested", score: 0.9)
    @suggestion.update!(receipt_link: link)
    @entry.lock_attr!(:notes)
    original_locks = @entry.reload.locked_attributes

    @suggestion.apply!(user: @owner, fields: %w[name category tags], split: true)

    assert @entry.reload.split_parent?
    assert @entry.child_entries.all?(&:reviewed?)
    assert_equal [ @kitchen.id, @outdoor.id ].sort, @entry.child_entries.map { |child| child.transaction.category_id }.sort
    assert link.reload.linked?

    @suggestion.revert!(user: @owner)

    @entry.reload
    transaction = @entry.transaction
    assert_not @entry.split_parent?
    assert_not @entry.excluded?
    assert_equal "AMAZON MKTPL 123", @entry.name
    assert_nil transaction.category_id
    assert_empty transaction.tags
    assert_nil transaction.extra["original_name"]
    assert_equal original_locks, @entry.locked_attributes
    assert_empty transaction.locked_attributes
    assert_not @entry.reviewed?
    assert link.reload.suggested?
    assert @suggestion.reload.reverted?
  end

  test "revert leaves fields the apply did not change, and later manual edits" do
    @suggestion.apply!(user: @owner, fields: %w[name category])
    @entry.reload.update!(notes: "edited later")
    @entry.transaction.update!(category: categories(:food_and_drink))

    @suggestion.revert!(user: @owner)

    @entry.reload
    assert_equal "AMAZON MKTPL 123", @entry.name
    assert_equal "edited later", @entry.notes
    assert_equal categories(:food_and_drink), @entry.transaction.category
  end

  test "a stale copy cannot apply or revert twice" do
    stale = TransactionAnnotationSuggestion.find(@suggestion.id)
    @suggestion.apply!(user: @owner, fields: %w[category])

    assert_raises(TransactionAnnotationSuggestion::Applier::Error) { stale.apply!(user: @owner, fields: %w[name]) }
    assert_equal "AMAZON MKTPL 123", @entry.reload.name

    stale_applied = TransactionAnnotationSuggestion.find(@suggestion.id)
    @suggestion.revert!(user: @owner)
    assert_raises(TransactionAnnotationSuggestion::Applier::Error) { stale_applied.revert!(user: @owner) }
  end

  test "a read_write share can annotate but neither rename nor split" do
    account_shares(:depository_shared_with_member).update!(permission: "read_write")

    selection = @suggestion.default_selection(@member)
    assert_not_includes selection.keys, "name"
    assert_not_includes selection.keys, "split"

    @suggestion.apply!(user: @member, fields: %w[name category], split: true)

    @entry.reload
    assert_equal "AMAZON MKTPL 123", @entry.name
    assert_equal @kitchen, @entry.transaction.category
    assert_not @entry.split_parent?
  end

  test "a read_only share cannot apply" do
    account_shares(:depository_shared_with_member).update!(permission: "read_only")

    assert_raises(TransactionAnnotationSuggestion::Applier::Error) do
      @suggestion.apply!(user: @member, fields: %w[category])
    end
    assert_not @entry.reload.reviewed?
  end
end
