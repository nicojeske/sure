# An AI or learned proposal for annotating one transaction entry, kept so the
# same receipt or hint is never sent to the LLM twice and so an applied
# proposal can be undone from its snapshot.
#
# payload (string keys): name, notes, category_id, merchant_id or
# new_merchant_name, tag_ids, confidence, rationale, receipt_amount_mismatch,
# and split: nil or [{ name, amount (signed decimal string), category_id,
# tag_ids, notes }] that adds up to the entry amount.
class TransactionAnnotationSuggestion < ApplicationRecord
  FIELDS = %w[name merchant category tags notes].freeze

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

  def split
    payload["split"].presence
  end

  def applicable?
    ready? || reverted?
  end

  # The FIELDS whose proposed value differs from the entry's current one.
  def proposed_fields
    transaction = entry.transaction

    FIELDS.select do |field|
      case field
      when "name" then payload["name"].present? && payload["name"] != entry.name
      when "notes" then payload["notes"].present? && payload["notes"] != entry.notes
      when "category" then payload["category_id"].present? && payload["category_id"] != transaction.category_id && transaction.category_editable?
      when "merchant" then payload["new_merchant_name"].present? || (payload["merchant_id"].present? && payload["merchant_id"] != transaction.merchant_id)
      when "tags" then payload["tag_ids"].present? && payload["tag_ids"].sort != transaction.tag_ids.sort
      end
    end
  end

  # { field => checked } for the fields this user may apply, plus "split"
  # when a split is proposed and allowed. A field starts checked when it is
  # empty or was set automatically (AI, Bayes, provider, rule); a value the
  # user set is locked and starts unchecked.
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
      transaction = entry.transaction

      case field
      when "name" then !entry.locked?(:name)
      when "notes" then entry.notes.blank? || !entry.locked?(:notes)
      when "category" then transaction.category_id.nil? || !transaction.locked?(:category_id)
      when "merchant" then transaction.merchant_id.nil? || !transaction.locked?(:merchant_id)
      when "tags" then transaction.tag_ids.empty? || !transaction.locked?(:tag_ids)
      end
    end
end
