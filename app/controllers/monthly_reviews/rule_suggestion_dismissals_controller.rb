# "Never for this pattern" on a card's rule suggestion: the family stops being
# offered a rule for that pattern, in any month.
class MonthlyReviews::RuleSuggestionDismissalsController < ApplicationController
  include MonthlyReviewScoped

  before_action :set_entry

  def create
    dismissal = Current.family.rule_suggestion_dismissals.find_or_initialize_by(pattern_key: params[:pattern_key].to_s)
    dismissal.user ||= Current.user
    dismissal.save

    redirect_to review_card_path(@entry)
  end
end
