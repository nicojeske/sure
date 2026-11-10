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
  def image? = document_mime_type.to_s.start_with?("image/")

  # The two user decisions on a suggestion, named once here so the drawer
  # (ReceiptLinksController) and the receipts list (Receipts::LinksController) can't drift on what
  # "confirm" or "dismiss" means. Confirming does not touch the transaction's other links —
  # multiple linked documents per transaction are allowed (an invoice *and* a receipt).
  def confirm! = update!(status: "linked")
  def dismiss! = update!(status: "dismissed")

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

  # True when the document's structured total (if any) disagrees with the entry it's linked to —
  # drives the warning-toned receipt pill. Shared by TransactionsController's per-page preload
  # and the standalone rendering path so the two can't drift.
  # `tolerance` lets the monthly review accept small rounding/fee differences.
  def amount_conflicts_with?(entry, tolerance: 0)
    return false if document_amount.blank? || entry.nil?

    document_currency != entry.currency || (document_amount.round(2) - entry.amount.abs.round(2)).abs > tolerance
  end

  # The document's OCR text, read from Paperless (never the file). Cached
  # briefly so the review card can warm the next card's receipt ahead of time.
  # Raises Provider::Paperless::Error.
  def document_content
    Rails.cache.fetch([ "paperless/document_content", paperless_connection_id, document_id ], expires_in: CONTENT_CACHE_TTL) do
      connection = paperless_connection
      Provider::Paperless.new(base_url: connection.base_url, api_token: connection.api_token, verify_ssl: connection.verify_ssl)
        .document(document_id)["content"].to_s
    end
  end

  CONTENT_CACHE_TTL = 10.minutes
end
