# An AI or learned proposal for annotating one transaction entry, kept so the
# same receipt or hint is never sent to the LLM twice and so an applied
# proposal can be undone from its snapshot.
#
# payload (string keys): name, notes, category_id, merchant_id or
# new_merchant_name, tag_ids, confidence, rationale, receipt_amount_mismatch,
# and split: nil or [{ name, amount (signed decimal string), category_id,
# tag_ids, notes }] that adds up to the entry amount.
class TransactionAnnotationSuggestion < ApplicationRecord
  # Review field => attribute it sets, which is also its payload key.
  FIELD_ATTRIBUTES = {
    "name" => "name", "merchant" => "merchant_id", "category" => "category_id", "tags" => "tag_ids", "notes" => "notes"
  }.freeze
  FIELDS = FIELD_ATTRIBUTES.keys.freeze
  ENTRY_FIELDS = %w[name notes].freeze
  # A pending row untouched for this long lost its worker and may be run again.
  PENDING_STALE_AFTER = 10.minutes

  belongs_to :entry
  belongs_to :family
  belongs_to :receipt_link, optional: true

  enum :source, { receipt: "receipt", hint: "hint", learned: "learned" }, validate: true
  enum :status, { pending: "pending", ready: "ready", failed: "failed", applied: "applied", reverted: "reverted" }, validate: true

  validates :input_hash, presence: true, uniqueness: { scope: :entry_id }

  # Values saved from a review card's edit mode (payload "edited"), stored as
  # a proposal so they apply and undo like one.
  scope :not_edited, -> { where("NOT (payload @> ?)", { edited: true }.to_json) }

  # Identifies the input a proposal was built from: a Paperless document id
  # for receipts, the whitespace- and case-normalized text for hints.
  def self.input_hash_for(source, input)
    normalized = input.to_s.squish.downcase
    Digest::SHA256.hexdigest("#{source}:#{normalized}")
  end

  # The record a field's attribute lives on: the entry or its transaction.
  def self.record_for(field, entry)
    ENTRY_FIELDS.include?(field) ? entry : entry.transaction
  end

  # Returns the suggestion for this input, creating it when missing; a
  # concurrent insert of the same input loses on the unique index and gets
  # the winner's row instead.
  def self.find_or_create_for!(entry, input_hash:, **attributes)
    find_by(entry_id: entry.id, input_hash: input_hash) ||
      transaction(requires_new: true) { create!(entry: entry, input_hash: input_hash, **attributes) }
  rescue ActiveRecord::RecordNotUnique
    where(entry_id: entry.id, input_hash: input_hash).take!
  end

  # Claims the right to run this input in the background: creates its pending
  # row, or takes over a stale pending one (and a failed one when
  # `retry_failed`: true for any, a Time for those that failed before it).
  # Returns nil when the input already has a result or another run owns it.
  def self.claim_for(entry, input_hash:, retry_failed: false, **attributes)
    suggestion = find_or_create_for!(entry, input_hash: input_hash, status: "pending", **attributes)
    return suggestion if suggestion.previously_new_record?

    reclaimable = where(status: "pending", updated_at: ...PENDING_STALE_AFTER.ago)
    if retry_failed
      failed = where(status: "failed")
      failed = failed.where(updated_at: ...retry_failed) if retry_failed.is_a?(Time)
      reclaimable = reclaimable.or(failed)
    end
    claimed = where(id: suggestion.id).and(reclaimable).update_all(status: "pending", error: nil, updated_at: Time.current)
    claimed == 1 ? suggestion.reload : nil
  end

  # The suggestion whose apply marked `entry` reviewed, or nil when the entry
  # was marked reviewed some other way (or reviewed again after it). For a
  # split part that is the split parent's suggestion that split it.
  def self.applied_in_review_of(entry)
    return nil unless entry.reviewed?

    owner = entry.split_child? ? entry.parent_entry : entry
    suggestions = owner.annotation_suggestions.applied.where(updated_at: entry.reviewed_at..)
    suggestions = suggestions.where("applied_fields ->> 'split' = 'true'") if owner != entry
    suggestions.order(updated_at: :desc).first
  end

  def edited?
    payload&.dig("edited") == true
  end

  # A pending row some run is still working on.
  def in_flight?
    pending? && updated_at > PENDING_STALE_AFTER.ago
  end

  # Whether a background run may claim this row (see claim_for).
  def reclaimable?(retry_failed: false)
    return true if pending? && !in_flight?
    return false unless failed? && retry_failed

    !retry_failed.is_a?(Time) || updated_at < retry_failed
  end

  def split
    payload["split"].presence
  end

  def applicable?
    ready? || reverted?
  end

  # The FIELDS whose proposed value differs from the entry's current one.
  def proposed_fields
    FIELDS.select do |field|
      attribute = FIELD_ATTRIBUTES[field]
      proposed = payload[attribute]
      current = self.class.record_for(field, entry).public_send(attribute)

      case field
      when "merchant" then payload["new_merchant_name"].present? || (proposed.present? && proposed != current)
      when "tags" then proposed.present? && proposed.sort != current.sort
      when "category" then proposed.present? && proposed != current && entry.transaction.category_editable?
      else proposed.present? && proposed != current
      end
    end
  end

  # { field => checked } for the fields this user may apply, plus "split"
  # when a split is proposed and allowed. A field starts checked when it is
  # empty or was set automatically (AI, Bayes, provider, rule); a value the
  # user set starts unchecked (see Enrichable#set_by_user?).
  def default_selection(user)
    permitted = Applier.permitted_fields(entry, user)
    selection = (proposed_fields & permitted).index_with { |field| default_checked?(field) }
    selection["split"] = true if split && Applier.can_split?(entry, user)
    selection
  end

  def apply!(user:, fields:, split: false)
    Applier.new(self, user: user).apply!(fields: fields, split: split)
  end

  def revert!(user:)
    Applier.new(self, user: user).revert!
  end

  private
    def default_checked?(field)
      record = self.class.record_for(field, entry)
      attribute = FIELD_ATTRIBUTES[field]

      record.public_send(attribute).blank? || !record.set_by_user?(attribute)
    end
end
