require "digest/md5"

# Retroactively applies Family#name_prefix_stripper (built-in defaults + this family's
# configured tokens) to Enable Banking-sourced transactions and merchants that were
# imported before the stripping was in place (or before a new prefix was added to the
# family's settings).
#
# Deliberately Enable Banking-only, matching where EnableBankingEntry::Processor applies
# this at import time -- see Transaction::NamePrefixStripper.
class Family::NamePrefixBackfill
  Result = Struct.new(:entries_updated, :merchants_renamed, :merchants_merged, keyword_init: true)

  SOURCE = "enable_banking"

  def initialize(family)
    @family = family
    @stripper = family.name_prefix_stripper
  end

  # dry_run: true counts what *would* change without writing anything.
  def call(dry_run: false)
    entries_updated = backfill_entries(dry_run: dry_run)
    merchants_renamed, merchants_merged = backfill_merchants(dry_run: dry_run)

    Result.new(entries_updated: entries_updated, merchants_renamed: merchants_renamed, merchants_merged: merchants_merged)
  end

  private
    attr_reader :family, :stripper

    def backfill_entries(dry_run:)
      count = 0

      candidate_entries_scope.find_each do |entry|
        cleaned = stripper.call(entry.name)
        next if cleaned == entry.name

        count += 1
        next if dry_run

        # source: "enable_banking" (not "rule" or a generic backfill source) because this
        # is retroactively applying what import-time stripping would have produced --
        # consistent with how DataEnrichment records this attribute during a normal sync.
        entry.enrich_attribute(:name, cleaned, source: SOURCE)
      end

      count
    end

    # Prefiltered to entries whose name could plausibly start with one of the
    # configured tokens, and excludes name-locked entries (mirrors
    # Rule::ActionExecutor::SetTransactionName) so a full family sync doesn't have to
    # load every entry just to find the handful that still need cleaning.
    def candidate_entries_scope
      scope = family.entries
        .where(entryable_type: "Transaction", source: SOURCE)
        .where.not(Arel.sql("entries.locked_attributes ? 'name'"))

      return scope.none if stripper.prefixes.empty?

      clauses = stripper.prefixes.map { "entries.name ILIKE ?" }.join(" OR ")
      binds = stripper.prefixes.map { |token| "#{token}*%" }
      scope.where(clauses, *binds)
    end

    def backfill_merchants(dry_run:)
      renamed = 0
      merged = 0

      (affected_provider_merchants.to_a + family.merchants.to_a).each do |merchant|
        clean_name = stripper.call(merchant.name)
        next if clean_name == merchant.name

        target = existing_target_for(merchant, clean_name)

        if target
          merged += 1
          merge_merchant!(merchant, target) unless dry_run
        else
          renamed += 1
          rename_merchant!(merchant, clean_name) unless dry_run
        end
      end

      [ renamed, merged ]
    end

    # ProviderMerchants are shared across families (found by [source, name], not
    # family-scoped -- see EnableBankingEntry::Processor#merchant), so we only touch the
    # ones actually assigned to one of this family's transactions rather than scanning
    # every ProviderMerchant in the system.
    def affected_provider_merchants
      merchant_ids = family.transactions
        .where.not(merchant_id: nil)
        .joins(:merchant)
        .where(merchants: { type: "ProviderMerchant", source: SOURCE })
        .distinct
        .pluck(:merchant_id)

      ProviderMerchant.where(id: merchant_ids)
    end

    def existing_target_for(merchant, clean_name)
      if merchant.is_a?(ProviderMerchant)
        ProviderMerchant.find_by(source: merchant.source, name: clean_name)
      else
        family.merchants.find_by(name: clean_name)
      end
    end

    # Deliberately does NOT call Entry.mark_user_modified_for_transactions! (unlike
    # Merchant::Merger#merge! and ProviderMerchant#convert_to_family_merchant_for): those
    # protect a *manual* reassignment from being reverted by the next sync. This is a
    # text cleanup, not a user decision -- freezing these entries would permanently
    # exclude them from future provider sync.
    def merge_merchant!(source_merchant, target_merchant)
      family.transactions.where(merchant_id: source_merchant.id).update_all(merchant_id: target_merchant.id)

      if source_merchant.is_a?(FamilyMerchant)
        source_merchant.destroy!
      elsif source_merchant.is_a?(ProviderMerchant) && !Transaction.where(merchant_id: source_merchant.id).exists?
        # Only delete if no family (not just this one) still references it -- a
        # ProviderMerchant may be shared cross-family.
        source_merchant.destroy!
      end
    end

    def rename_merchant!(merchant, clean_name)
      if merchant.is_a?(ProviderMerchant)
        merchant.update!(name: clean_name, provider_merchant_id: "enable_banking_merchant_#{Digest::MD5.hexdigest(clean_name.downcase)}")
      else
        merchant.update!(name: clean_name)
      end
    end
end
