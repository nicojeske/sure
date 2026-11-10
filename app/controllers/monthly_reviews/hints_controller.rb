# A typed hint ("Apfelentkerner + Handwärmer") for the card's transaction:
# the AI builds a proposal from it (plus the card's receipt, if any) and the
# card shows that proposal next.
class MonthlyReviews::HintsController < ApplicationController
  include MonthlyReviewScoped

  before_action :set_entry

  def create
    text = params[:hint].to_s.strip
    return redirect_to(review_card_path(@entry)) if text.blank?

    suggestion = request_suggestion(hint: text)

    redirect_to review_card_path(@entry, suggestion_id: suggestion.id)
  end
end
