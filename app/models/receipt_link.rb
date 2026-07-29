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
end
