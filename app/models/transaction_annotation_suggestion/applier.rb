# Applies the fields of an annotation suggestion a user selected, as that
# user's own edit, and marks the entry reviewed; revert! undoes exactly that
# from the snapshot taken first.
#
# Permissions follow the account share: full control (or ownership) may
# rename and split; read_write may only annotate (AccountShare::ANNOTATE_*);
# anything less may not apply at all.
class TransactionAnnotationSuggestion::Applier
  Error = Class.new(StandardError)

  ANNOTATE_FIELDS = %w[merchant category tags notes].freeze
  FULL_CONTROL = %i[owner full_control].freeze

  def self.permitted_fields(entry, user)
    case entry.account.permission_for(user)
    when *FULL_CONTROL then TransactionAnnotationSuggestion::FIELDS
    when :read_write then ANNOTATE_FIELDS
    else []
    end
  end

  def self.can_split?(entry, user)
    entry.account.permission_for(user).in?(FULL_CONTROL) && entry.transaction.splittable?
  end

  attr_reader :suggestion, :user, :entry

  def initialize(suggestion, user:)
    @suggestion = suggestion
    @user = user
    @entry = suggestion.entry
  end

  def apply!(fields:, split: false)
    raise Error, "Suggestion is #{suggestion.status}, not applicable" unless suggestion.applicable?

    permitted = self.class.permitted_fields(entry, user)
    raise Error, "Not allowed to annotate this transaction" if permitted.empty?

    fields = Array(fields).map(&:to_s) & suggestion.proposed_fields & permitted
    split = split && suggestion.split.present? && self.class.can_split?(entry, user)
    payload = suggestion.payload
    transaction = entry.transaction

    Entry.transaction do
      snapshot = take_snapshot
      merchant_id, created_merchant_id = resolve_merchant(payload) if fields.include?("merchant")

      if fields.include?("name") && transaction.extra["original_name"].blank?
        transaction.update!(extra: transaction.extra.merge("original_name" => entry.name))
      end

      if fields.any?
        Entry.where(id: entry.id).bulk_update!(
          {
            name: (payload["name"] if fields.include?("name")),
            notes: (payload["notes"] if fields.include?("notes")),
            category_id: (payload["category_id"] if fields.include?("category")),
            merchant_id: merchant_id,
            tag_ids: (payload["tag_ids"] if fields.include?("tags"))
          },
          update_tags: fields.include?("tags")
        )
        lock_applied_attributes(fields)
      end

      if split && !entry.split_once!(split_rows(payload["split"], merchant_id), lock_attributes: true)
        raise Error, "Transaction can no longer be split"
      end

      confirmed_link = suggestion.receipt_link if suggestion.receipt_link&.suggested?
      confirmed_link&.confirm!

      entry.mark_reviewed!(user)
      suggestion.update!(
        status: "applied",
        snapshot: snapshot,
        applied_fields: {
          "fields" => fields,
          "split" => split,
          "confirmed_receipt_link_id" => confirmed_link&.id,
          "created_merchant_id" => created_merchant_id
        }
      )
    end

    entry.sync_account_later if split
    suggestion
  end

  def revert!
    raise Error, "Suggestion is #{suggestion.status}, not applied" unless suggestion.applied?

    applied = suggestion.applied_fields || {}
    raise Error, "Not allowed to annotate this transaction" if self.class.permitted_fields(entry, user).empty?
    raise Error, "Not allowed to undo a split" if applied["split"] && !entry.account.permission_for(user).in?(FULL_CONTROL)

    snapshot = suggestion.snapshot

    Entry.transaction do
      entry.unsplit_once! if applied["split"]

      entry.reload.update!(
        name: snapshot["name"],
        notes: snapshot["notes"],
        user_modified: snapshot["user_modified"],
        locked_attributes: snapshot["entry_locked_attributes"]
      )

      transaction = entry.transaction
      extra = transaction.extra.except("original_name")
      extra["original_name"] = snapshot["original_name"] if snapshot["original_name"]
      transaction.update!(
        category_id: snapshot["category_id"],
        merchant_id: snapshot["merchant_id"],
        tag_ids: snapshot["tag_ids"],
        locked_attributes: snapshot["transaction_locked_attributes"],
        extra: extra
      )

      if (link_id = applied["confirmed_receipt_link_id"])
        transaction.receipt_links.where(id: link_id).update_all(status: "suggested", updated_at: Time.current)
      end

      entry.unmark_reviewed!
      suggestion.update!(status: "reverted")
    end

    entry.sync_account_later if applied["split"]
    suggestion
  end

  private
    def take_snapshot
      transaction = entry.transaction

      {
        "name" => entry.name,
        "notes" => entry.notes,
        "user_modified" => entry.user_modified,
        "entry_locked_attributes" => entry.locked_attributes,
        "category_id" => transaction.category_id,
        "merchant_id" => transaction.merchant_id,
        "tag_ids" => transaction.tag_ids,
        "transaction_locked_attributes" => transaction.locked_attributes,
        "original_name" => transaction.extra["original_name"]
      }
    end

    # bulk_update! locks only what its last save changed, which misses the
    # entry's fields once tags are saved after them.
    def lock_applied_attributes(fields)
      entry.reload
      entry_locks = { "name" => "name", "notes" => "notes" }.slice(*fields).values
      transaction_locks = { "category" => "category_id", "merchant" => "merchant_id", "tags" => "tag_ids" }.slice(*fields).values
      now = Time.current

      entry.update!(locked_attributes: entry.locked_attributes.merge(entry_locks.index_with { now })) if entry_locks.any?
      if transaction_locks.any?
        entry.transaction.update!(locked_attributes: entry.transaction.locked_attributes.merge(transaction_locks.index_with { now }))
      end
    end

    # [merchant_id, id of a merchant created for it or nil]
    def resolve_merchant(payload)
      return [ payload["merchant_id"], nil ] if payload["new_merchant_name"].blank?

      merchant, created = FamilyMerchant.find_or_create_with_name(suggestion.family, payload["new_merchant_name"])
      [ merchant.id, (merchant.id if created) ]
    end

    def split_rows(split, merchant_id)
      split.map do |row|
        {
          name: row["name"],
          amount: row["amount"].to_d,
          category_id: row["category_id"],
          merchant_id: merchant_id,
          tag_ids: row["tag_ids"] || [],
          notes: row["notes"]
        }
      end
    end
end
