# Reads one card's receipt (MonthlyReview#read_receipt_later claimed it) and
# refreshes the card. On the high-priority AI queue: someone is looking at
# that card.
class MonthlyReview::ReadReceiptJob < ApplicationJob
  queue_as :ai_high_priority

  def perform(suggestion, user)
    return unless suggestion.pending? && suggestion.receipt_link && user.family_id == suggestion.family_id

    entry = suggestion.entry
    Transaction::AnnotationSuggester.new(suggestion.family, user: user).suggest_from_receipt(entry, suggestion.receipt_link)
    Turbo::StreamsChannel.broadcast_refresh_to(suggestion.family, :monthly_review, entry)
  end
end
