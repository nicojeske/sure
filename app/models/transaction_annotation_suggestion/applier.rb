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
  FIELD_ATTRIBUTES = TransactionAnnotationSuggestion::FIELD_ATTRIBUTES

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
    permitted = self.class.permitted_fields(entry, user)
    raise Error, "Not allowed to annotate this transaction" if permitted.empty?

    Entry.transaction do
      suggestion.lock!
      raise Error, "Suggestion is #{suggestion.status}, not applicable" unless suggestion.applicable?

      entry.reload
      fields = Array(fields).map(&:to_s) & suggestion.proposed_fields & permitted
      split = split && suggestion.split.present? && self.class.can_split?(entry, user)
      payload = suggestion.payload
      transaction = entry.transaction
      snapshot = take_snapshot

      values = fields.to_h { |field| [ FIELD_ATTRIBUTES[field], payload[FIELD_ATTRIBUTES[field]] ] }
      values["merchant_id"], created_merchant_id = resolve_merchant(payload) if fields.include?("merchant")

      if fields.include?("name") && transaction.extra["original_name"].blank?
        transaction.update!(extra: transaction.extra.merge("original_name" => entry.name))
      end

      if fields.any?
        Entry.where(id: entry.id).bulk_update!(values.symbolize_keys, update_tags: fields.include?("tags"))
        lock_applied_attributes(fields, snapshot)
      end

      if split && !entry.split_once!(split_rows(payload["split"], values["merchant_id"]), lock_attributes: true)
        raise Error, "Transaction can no longer be split"
      end

      confirmed_link = suggestion.receipt_link if suggestion.receipt_link&.suggested?
      confirmed_link&.confirm!

      entry.mark_reviewed!(user)
      # The parts were reviewed together with the proposal; they would
      # otherwise come back as new cards in the queue.
      entry.child_entries.each { |child| child.mark_reviewed!(user) } if split
      suggestion.update!(
        status: "applied",
        snapshot: snapshot,
        applied_fields: {
          "fields" => fields,
          "values" => values,
          "split" => split,
          "confirmed_receipt_link_id" => confirmed_link&.id,
          "created_merchant_id" => created_merchant_id
        }
      )
      @split_applied = split
    end

    entry.sync_account_later if @split_applied
    suggestion
  end

  # Restores only what the apply changed, and only where the value is still
  # the applied one, so edits made after accepting survive the undo.
  def revert!
    raise Error, "Not allowed to annotate this transaction" if self.class.permitted_fields(entry, user).empty?

    Entry.transaction do
      suggestion.lock!
      raise Error, "Suggestion is #{suggestion.status}, not applied" unless suggestion.applied?

      applied = suggestion.applied_fields || {}
      raise Error, "Not allowed to undo a split" if applied["split"] && !entry.account.permission_for(user).in?(FULL_CONTROL)

      entry.unsplit_once! if applied["split"]
      entry.reload

      fields = Array(applied["fields"])
      restorable = fields.select { |field| unchanged_since_apply?(field, applied["values"] || {}) }
      restore_fields(restorable, all_restored: restorable.size == fields.size)

      if (link_id = applied["confirmed_receipt_link_id"])
        entry.transaction.receipt_links.where(id: link_id).update_all(status: "suggested", updated_at: Time.current)
      end

      entry.unmark_reviewed!
      suggestion.update!(status: "reverted")
      @split_reverted = applied["split"]
    end

    entry.sync_account_later if @split_reverted
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

    def record_for(field)
      TransactionAnnotationSuggestion.record_for(field, entry)
    end

    # Sets the locks to what they were plus the applied attributes.
    # bulk_update!'s own locking misses the entry's fields once tags are saved
    # after them, and locks "locked_attributes" itself after the tag lock.
    def lock_applied_attributes(fields, snapshot)
      entry.reload
      now = Time.current
      locks_before = { entry => snapshot["entry_locked_attributes"], entry.transaction => snapshot["transaction_locked_attributes"] }

      locks_before.each do |record, before|
        record_fields = fields.select { |field| record_for(field) == record }
        locks = before.merge(record_fields.map { |field| FIELD_ATTRIBUTES[field] }.index_with { now })
        record.update!(locked_attributes: locks) if locks != record.locked_attributes
      end
    end

    def unchanged_since_apply?(field, values)
      attribute = FIELD_ATTRIBUTES[field]
      current = record_for(field).public_send(attribute)
      applied = values[attribute]

      current.is_a?(Array) ? current.map(&:to_s).sort == Array(applied).map(&:to_s).sort : current.to_s == applied.to_s
    end

    def restore_fields(fields, all_restored:)
      snapshot = suggestion.snapshot
      locks_before = {
        entry => snapshot["entry_locked_attributes"] || {},
        entry.transaction => snapshot["transaction_locked_attributes"] || {}
      }

      fields.group_by { |field| record_for(field) }.each do |record, record_fields|
        attributes = record_fields.map { |field| FIELD_ATTRIBUTES[field] }
        locks = record.locked_attributes.except(*attributes).merge(locks_before[record].slice(*attributes))
        record.update!(attributes.index_with { |attribute| snapshot[attribute] }.merge(locked_attributes: locks))
      end

      if fields.include?("name")
        transaction = entry.transaction
        extra = transaction.extra.except("original_name")
        extra["original_name"] = snapshot["original_name"] if snapshot["original_name"]
        transaction.update!(extra: extra)
      end

      entry.update!(user_modified: snapshot["user_modified"]) if all_restored
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
