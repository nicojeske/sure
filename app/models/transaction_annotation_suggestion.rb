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

  belongs_to :entry
  belongs_to :family
  belongs_to :receipt_link, optional: true

  enum :source, { receipt: "receipt", hint: "hint", learned: "learned" }, validate: true
  enum :status, { pending: "pending", ready: "ready", failed: "failed", applied: "applied", reverted: "reverted" }, validate: true

  validates :input_hash, presence: true, uniqueness: { scope: :entry_id }

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
