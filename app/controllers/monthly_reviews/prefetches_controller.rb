# The refresh button: reads every receipt-backed card of the queue again in
# the background, retrying the ones that failed.
class MonthlyReviews::PrefetchesController < ApplicationController
  include MonthlyReviewScoped

  def create
    @monthly_review.prefetch_suggestions_later(Current.user, include_transfers: include_transfers?, force: true)

    # Back to the card on screen: the button sits outside the card's frame, so
    # the page URL (the referrer) is the one that follows the cards.
    redirect_back_or_to review_card_path, notice: t(".started")
  end
end
