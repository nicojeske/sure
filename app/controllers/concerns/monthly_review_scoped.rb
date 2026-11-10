# Shared by the monthly review card controllers: the preview gate, the review
# for the :monthly_review_month_year param (Budget format, e.g. "oct-2026"),
# the month's entries the user may annotate, and card URLs that keep the
# "include transfers" toggle.
module MonthlyReviewScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_preview_features!
    before_action :set_monthly_review

    helper_method :include_transfers?, :review_card_path
  end

  private
    def set_monthly_review
      date = Budget.param_to_date(params[:monthly_review_month_year].to_s, family: Current.family)
      @monthly_review = MonthlyReview.for(Current.family, date)
    rescue Date::Error
      raise ActiveRecord::RecordNotFound
    end

    def include_transfers?
      params[:include_transfers] == "1"
    end

    def review_entries
      @monthly_review.month_entries(Current.annotatable_entries, include_transfers: include_transfers?)
    end

    def set_entry
      @entry = review_entries.find(params[:entry_id])
    end

    def review_card_path(entry = nil, **options)
      monthly_review_card_path(
        @monthly_review,
        { entry_id: entry&.id, include_transfers: ("1" if include_transfers?) }.merge(options).compact
      )
    end

    def suggester
      Transaction::AnnotationSuggester.new(Current.family, user: Current.user)
    end

    # Runs a user-requested suggestion unless a run for the same input is
    # still in flight (usually the background prefetch); the card then shows
    # a spinner and refreshes when that run is done.
    def suggest_unless_in_flight(input_hash)
      existing = @entry.annotation_suggestions.find_by(input_hash: input_hash)
      existing&.in_flight? ? existing : yield
    end
end
