module MonthlyReviewsHelper
  # Receipt text scroll areas: viewport-high in the receipt column, 12rem
  # inside the card.
  RECEIPT_SCROLL_CLASSES = { "wide" => "max-h-[calc(100vh-12rem)]", "narrow" => "max-h-48" }.freeze

  # Pill tone and icon of each review status.
  REVIEW_STATUS_PILLS = {
    completed: [ :success, "circle-check" ],
    ready: [ :info, "flag" ],
    in_progress: [ :warning, "circle-dot" ],
    not_started: [ :neutral, "circle" ],
    empty: [ :neutral, "circle-dashed" ]
  }.freeze

  def review_month_label(review)
    l(review.start_date, format: :month_year)
  end

  def review_status_pill(status)
    tone, icon = REVIEW_STATUS_PILLS.fetch(status)
    render DS::Pill.new(label: t("monthly_reviews.status.#{status}"), tone: tone, icon: icon, marker: false)
  end

  def review_progress_tone(progress)
    progress.total.positive? && progress.done? ? :success : :neutral
  end

  def review_progress_caption(progress)
    return t("monthly_reviews.progress.none") if progress.total.zero?

    t("monthly_reviews.progress.reviewed", reviewed: progress.reviewed, total: progress.total)
  end

  # The summary's way into the cards: start, continue with what is left, or
  # reopen the cards once everything is reviewed.
  def review_cards_link(progress)
    text =
      if progress.done? then t("monthly_reviews.cards_link.open")
      elsif progress.reviewed.zero? then t("monthly_reviews.cards_link.start")
      else t("monthly_reviews.cards_link.continue", count: progress.remaining)
      end

    render DS::Link.new(text: text, variant: progress.done? ? :outline : :primary, icon: "list-checks", href: review_card_path)
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
