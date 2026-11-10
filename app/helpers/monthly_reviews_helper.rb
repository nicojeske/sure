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

  def review_status(review, progress)
    if review.completed? then :completed
    elsif progress.total.zero? then :empty
    elsif progress.done? then :ready
    elsif progress.reviewed.positive? then :in_progress
    else :not_started
    end
  end

  def review_status_pill(review, progress)
    status = review_status(review, progress)
    tone, icon = REVIEW_STATUS_PILLS.fetch(status)
    render DS::Pill.new(label: t("monthly_reviews.status.#{status}"), tone: tone, icon: icon, marker: false)
  end

  def review_progress_percent(progress)
    progress.total.zero? ? 0 : progress.reviewed * 100 / progress.total
  end

  def review_progress_tone(progress)
    progress.total.positive? && progress.done? ? :success : :neutral
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
