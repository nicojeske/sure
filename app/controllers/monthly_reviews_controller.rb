# The monthly review overview (the latest months and their progress) and a
# month's summary page, where the month gets its note and is completed.
class MonthlyReviewsController < ApplicationController
  include MonthlyReviewScoped

  skip_before_action :set_monthly_review, only: :index
  before_action :require_non_guest!, only: :update
  before_action :require_review_editor!, only: :update

  helper_method :can_edit_review?

  def index
    @overview = MonthlyReview::Overview.new(Current.family, Current.annotatable_entries, include_transfers: include_transfers?)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.monthly_reviews"), nil ] ]
  end

  def show
    @summary = MonthlyReview::Summary.new(@monthly_review, Current.annotatable_entries, user: Current.user, include_transfers: include_transfers?)
    set_review_breadcrumbs
  end

  def update
    @monthly_review.update!(monthly_review_params)

    notice =
      case params[:completion]
      when "complete"
        @monthly_review.complete!
        t(".completed")
      when "reopen"
        @monthly_review.reopen!
        t(".reopened")
      else
        t(".saved")
      end

    redirect_to monthly_review_path(@monthly_review, transfers_param), notice: notice
  end

  private
    # The note and completion belong to the people who review: a member who
    # can only read shared accounts has no card to review either.
    def can_edit_review?
      !Current.user.guest? && Current.family.accounts.annotatable_by(Current.user).exists?
    end

    def require_review_editor!
      redirect_to monthly_review_path(@monthly_review, transfers_param), alert: t(".not_allowed") unless can_edit_review?
    end

    def monthly_review_params
      params.fetch(:monthly_review, {}).permit(:notes)
    end
end
