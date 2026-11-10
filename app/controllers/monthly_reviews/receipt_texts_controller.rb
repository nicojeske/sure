# The OCR text of a card's receipt, loaded lazily into the card so the card
# itself never waits for Paperless.
class MonthlyReviews::ReceiptTextsController < ApplicationController
  include MonthlyReviewScoped
  include PaperlessErrorCapturing

  before_action :set_entry

  def show
    @receipt_link = @entry.transaction.receipt_links.find(params[:receipt_link_id])
    @variant = params[:variant] == "narrow" ? "narrow" : "wide"

    begin
      @content = @receipt_link.document_content
    rescue Provider::Paperless::Error => e
      capture_paperless_error(
        e, source: "#{self.class.name}#show", message: "Paperless receipt text failed", level: "warn", account: @entry.account,
        receipt_link_id: @receipt_link.id, paperless_document_id: @receipt_link.document_id
      )
      @failed = true
    end
  end
end
