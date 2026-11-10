# Shared by the monthly review controllers: the preview gate, the review for
# the month param (Budget format, e.g. "oct-2026"), the month's entries the
# user may annotate, card URLs that keep the "include transfers" toggle, and
# the breadcrumb trail.
module MonthlyReviewScoped
  extend ActiveSupport::Concern

  included do
    before_action :require_preview_features!
    before_action :set_monthly_review

    helper_method :include_transfers?, :transfers_param, :review_card_path
  end

  private
    def set_monthly_review
      @monthly_review = MonthlyReview.for(Current.family, review_date)
    end

    # The month param as a date, 404 when it doesn't parse or lies outside
    # the months budgets cover.
    def review_date
      param = params[:monthly_review_month_year] || params[:month_year]
      date = Budget.param_to_date(param.to_s, family: Current.family)
      raise ActiveRecord::RecordNotFound unless Budget.budget_date_valid?(date, family: Current.family)

      date
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

    # Home > Monthly review > October 2026 > `trail`.
    def set_review_breadcrumbs(*trail)
      @breadcrumbs = [
        [ t("breadcrumbs.home"), root_path ],
        [ t("breadcrumbs.monthly_reviews"), monthly_reviews_path(year: @monthly_review.start_date.year, **transfers_param) ],
        [ helpers.review_month_label(@monthly_review), (monthly_review_path(@monthly_review, transfers_param) if trail.any?) ],
        *trail
      ]
    end

    def transfers_param
      { include_transfers: ("1" if include_transfers?) }.compact
    end

    def review_card_path(entry = nil, **options)
      monthly_review_card_path(
        @monthly_review,
        { entry_id: entry&.id, **transfers_param }.merge(options).compact
      )
    end

    def suggester
      Transaction::AnnotationSuggester.new(Current.family, user: Current.user)
    end

    # Runs a user-requested suggestion unless a run for the same input is
    # still in flight (usually the background prefetch); the card then shows
    # a spinner and refreshes when that run is done.
    def request_suggestion(receipt_link: nil, hint: nil)
      suggester.request_suggestion(@entry, receipt_link: receipt_link, hint: hint)
    end
end
