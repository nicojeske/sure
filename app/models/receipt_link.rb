# frozen_string_literal: true

class ReceiptLink < ApplicationRecord
  # Named `transaction_record`, not `transaction` — `transaction` is already a
  # method on ActiveRecord::Base (wraps a DB transaction) and Rails refuses to
  # define an association that shadows it.
  belongs_to :transaction_record, class_name: "Transaction", foreign_key: :transaction_id, inverse_of: :receipt_links
  belongs_to :paperless_connection

  scope :linked, -> { where(status: "linked") }
  scope :suggested, -> { where(status: "suggested") }
  scope :dismissed, -> { where(status: "dismissed") }
  scope :ordered, -> { order(score: :desc, created_at: :desc) }

  def linked? = status == "linked"
  def suggested? = status == "suggested"
  def dismissed? = status == "dismissed"

  # Shared by PaperlessConnection::Matcher and ReceiptLinksController#link_document, the two
  # places a document gets attached to a transaction — keeps the cached document_* columns
  # (used to render rows without a Paperless HTTP call) in sync in exactly one place.
  def apply_document_metadata(document, correspondent_name:, facts: nil)
    assign_attributes(
      document_title: document["title"],
      document_created_on: self.class.parse_document_date(document["created"]),
      document_correspondent: correspondent_name,
      document_mime_type: document["mime_type"],
      document_amount: facts&.total&.amount,
      document_currency: facts&.total&.currency&.iso_code,
      document_reference: facts&.reference
    )
  end

  def self.parse_document_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
