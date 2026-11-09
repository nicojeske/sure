# An AI or learned proposal for annotating one transaction entry, kept so the
# same receipt or hint is never sent to the LLM twice and so an applied
# proposal can be undone from its snapshot.
class TransactionAnnotationSuggestion < ApplicationRecord
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
end
