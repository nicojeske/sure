# Prefetches a review's receipt-backed proposals in batches: each run handles
# BATCH_SIZE receipts and queues the next batch, so a card's own receipt read
# (ReadReceiptJob, ai_high_priority) runs in between on a single AI thread
# instead of waiting for the whole month.
class MonthlyReview::PrefetchSuggestionsJob < ApplicationJob
  queue_as :ai_low_priority

  BATCH_SIZE = 10

  # `force` retries suggestions that failed before the run started;
  # `remaining` is what is left of the run's MonthlyReview::SuggestionPrefetch::LIMIT.
  def perform(monthly_review, user, include_transfers: false, force: false, remaining: MonthlyReview::SuggestionPrefetch::LIMIT, started_at: Time.current)
    return unless user.family_id == monthly_review.family_id

    batch = [ BATCH_SIZE, remaining ].min
    suggestions = monthly_review.prefetch_suggestions(user, include_transfers: include_transfers, retry_failed: (force && started_at), limit: batch) do |entry, _suggestion|
      Turbo::StreamsChannel.broadcast_refresh_to(monthly_review.family, :monthly_review, entry)
    end

    left = remaining - suggestions.size
    return unless suggestions.size == batch && left.positive?

    self.class.perform_later(monthly_review, user, include_transfers: include_transfers, force: force, remaining: left, started_at: started_at)
  end
end
