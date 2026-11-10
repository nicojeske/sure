# The OCR text of a card's receipt, loaded lazily into the card so the card
# itself never waits for Paperless.
class MonthlyReviews::ReceiptTextsController < ApplicationController
  include MonthlyReviewScoped

  # The receipt column caps the text at the viewport, the block in the card
  # at 12rem.
  SCROLL_CLASSES = { "wide" => "max-h-[calc(100vh-12rem)]", "narrow" => "max-h-48" }.freeze

  before_action :set_entry

  def show
    @receipt_link = @entry.transaction.receipt_links.find(params[:receipt_link_id])
    variant = SCROLL_CLASSES.key?(params[:variant]) ? params[:variant] : "wide"
    @frame_id = "receipt_text_#{variant}_#{@receipt_link.id}"
    @scroll_class = SCROLL_CLASSES.fetch(variant)

    begin
      @content = @receipt_link.document_content
    rescue Provider::Paperless::Error => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "warn",
        message: "Paperless receipt text failed: #{e.message}",
        source: "#{self.class.name}#show",
        provider_key: "paperless",
        family: Current.family,
        account: @entry.account,
        metadata: { error_type: e.error_type, receipt_link_id: @receipt_link.id, paperless_document_id: @receipt_link.document_id }
      )
      @failed = true
    end
  end
end
