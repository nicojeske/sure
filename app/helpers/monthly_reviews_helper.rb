module MonthlyReviewsHelper
  # Receipt text scroll areas: viewport-high in the receipt column, 12rem
  # inside the card.
  RECEIPT_SCROLL_CLASSES = { "wide" => "max-h-[calc(100vh-12rem)]", "narrow" => "max-h-48" }.freeze

  def review_month_label(review)
    l(review.start_date, format: :month_year)
  end

  def review_confidence_label(card)
    return nil if card.confidence.blank?

    number_to_percentage(card.confidence.to_f * 100, precision: 0)
  end

  # The receipt text frame of one copy (wide column or in the card) of a
  # card's receipt.
  def review_receipt_frame_id(variant, receipt_link)
    "receipt_text_#{variant}_#{receipt_link.id}"
  end

  def review_receipt_scroll_class(variant)
    RECEIPT_SCROLL_CLASSES.fetch(variant)
  end
end
