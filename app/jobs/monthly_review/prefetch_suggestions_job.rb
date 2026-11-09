class MonthlyReview::PrefetchSuggestionsJob < ApplicationJob
  queue_as :ai_low_priority

  def perform(monthly_review, user, include_transfers: false, force: false)
    return unless user.family_id == monthly_review.family_id

    monthly_review.prefetch_suggestions(user, include_transfers: include_transfers, retry_failed: force) do |entry, _suggestion|
      Turbo::StreamsChannel.broadcast_refresh_to(monthly_review.family, :monthly_review, entry)
    end
  end
end
