require "test_helper"

class Family::NamePrefixBackfillTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    @family = @account.family
  end

  test "cleans an entry name that still has a prefix" do
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking")

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "ALDI SUED", entry.reload.name
    assert_equal 1, result.entries_updated
  end

  test "does not touch an entry whose name is already clean" do
    entry = create_transaction(account: @account, name: "ALDI SUED", source: "enable_banking")

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "ALDI SUED", entry.reload.name
    assert_equal 0, result.entries_updated
  end

  test "does not touch a non-enable_banking entry" do
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "plaid")

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "CRV*ALDI SUED", entry.reload.name
    assert_equal 0, result.entries_updated
  end

  test "skips a name-locked entry" do
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking")
    entry.lock_attr!(:name)

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "CRV*ALDI SUED", entry.reload.name
    assert_equal 0, result.entries_updated
  end

  test "does not set user_modified when cleaning an entry" do
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking")

    Family::NamePrefixBackfill.new(@family).call

    assert_not entry.reload.user_modified?
  end

  test "dry_run counts changes without writing them" do
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking")

    result = Family::NamePrefixBackfill.new(@family).call(dry_run: true)

    assert_equal "CRV*ALDI SUED", entry.reload.name
    assert_equal 1, result.entries_updated
  end

  test "applies the family's custom prefixes in addition to the defaults" do
    @family.update!(stripped_name_prefixes: [ "Wallster" ])
    entry = create_transaction(account: @account, name: "Wallster*Bakery Vienna", source: "enable_banking")

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "Bakery Vienna", entry.reload.name
    assert_equal 1, result.entries_updated
  end

  test "renames a ProviderMerchant in place when no clean-named merchant already exists" do
    merchant = ProviderMerchant.create!(
      source: "enable_banking",
      name: "CRV*ALDI SUED",
      provider_merchant_id: "enable_banking_merchant_dirty"
    )
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking", merchant: merchant)

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "ALDI SUED", merchant.reload.name
    assert_equal "enable_banking_merchant_#{Digest::MD5.hexdigest("aldi sued")}", merchant.provider_merchant_id
    assert_equal merchant, entry.reload.transaction.merchant
    assert_equal 1, result.merchants_renamed
    assert_equal 0, result.merchants_merged
  end

  test "merges a dirty ProviderMerchant into an already-clean one and repoints transactions" do
    clean_merchant = ProviderMerchant.create!(
      source: "enable_banking",
      name: "ALDI SUED",
      provider_merchant_id: "enable_banking_merchant_clean"
    )
    dirty_merchant = ProviderMerchant.create!(
      source: "enable_banking",
      name: "CRV*ALDI SUED",
      provider_merchant_id: "enable_banking_merchant_dirty"
    )
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking", merchant: dirty_merchant)

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal clean_merchant, entry.reload.transaction.merchant
    assert_not ProviderMerchant.exists?(dirty_merchant.id)
    assert_equal 0, result.merchants_renamed
    assert_equal 1, result.merchants_merged
  end

  test "does not delete a merged ProviderMerchant still referenced by another family" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Checking", balance: 0, currency: "USD", accountable: Depository.new)

    clean_merchant = ProviderMerchant.create!(
      source: "enable_banking",
      name: "ALDI SUED",
      provider_merchant_id: "enable_banking_merchant_clean"
    )
    dirty_merchant = ProviderMerchant.create!(
      source: "enable_banking",
      name: "CRV*ALDI SUED",
      provider_merchant_id: "enable_banking_merchant_dirty"
    )
    entry = create_transaction(account: @account, name: "CRV*ALDI SUED", source: "enable_banking", merchant: dirty_merchant)
    create_transaction(account: other_account, name: "CRV*ALDI SUED", source: "enable_banking", merchant: dirty_merchant)

    Family::NamePrefixBackfill.new(@family).call

    assert_equal clean_merchant, entry.reload.transaction.merchant
    assert ProviderMerchant.exists?(dirty_merchant.id)
  end

  test "renames a FamilyMerchant in place when no clean-named merchant already exists" do
    merchant = @family.merchants.create!(name: "CRV*ALDI SUED")

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal "ALDI SUED", merchant.reload.name
    assert_equal 1, result.merchants_renamed
  end

  test "merges a dirty FamilyMerchant into an already-clean one and repoints transactions, destroying the dirty one" do
    clean_merchant = @family.merchants.create!(name: "ALDI SUED")
    dirty_merchant = @family.merchants.create!(name: "CRV*ALDI SUED")
    entry = create_transaction(account: @account, name: "Some entry", merchant: dirty_merchant)

    result = Family::NamePrefixBackfill.new(@family).call

    assert_equal clean_merchant, entry.reload.transaction.merchant
    assert_not FamilyMerchant.exists?(dirty_merchant.id)
    assert_equal 1, result.merchants_merged
  end

  test "dry_run does not rename or merge merchants" do
    merchant = @family.merchants.create!(name: "CRV*ALDI SUED")

    result = Family::NamePrefixBackfill.new(@family).call(dry_run: true)

    assert_equal "CRV*ALDI SUED", merchant.reload.name
    assert_equal 1, result.merchants_renamed
  end
end
