module MonthlyReviewsHelper
  # The dot a queue row shows: the card on screen, reviewed, passed over
  # without a decision (skipped) or still ahead.
  def review_list_status(entry, current_entry, index, current_index)
    return "current" if entry == current_entry
    return "reviewed" if entry.reviewed?

    current_index && index < current_index ? "skipped" : "pending"
  end

  def review_month_label(review)
    l(review.start_date, format: :month_year)
  end

  def review_confidence_label(card)
    return nil if card.confidence.blank?

    number_to_percentage(card.confidence.to_f * 100, precision: 0)
  end
end
