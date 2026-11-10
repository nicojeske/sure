# The card's inline Paperless search (key f): documents around the
# transaction date, and picking one links it and has the AI read it.
class MonthlyReviews::ReceiptSearchesController < ApplicationController
  include MonthlyReviewScoped
  include PaperlessErrorCapturing

  before_action :set_entry
  before_action :set_paperless_connection

  def index
    @query = params[:q].to_s.strip.presence || default_query
    @any_date = params[:any_date] == "1"
    @date_window = receipt_search.date_window unless @any_date
    @page = [ params[:page].to_i, 1 ].max

    begin
      @result = receipt_search.search(query: @query, page: @page, within_window: !@any_date)
    rescue Provider::Paperless::Error => e
      capture_error(e, "index")
      @search_failed = true
    end
  end

  def create
    link = receipt_search.link!(params.require(:document_id))
    suggestion = suggester.suggest_from_receipt(@entry, link)

    redirect_to review_card_path(@entry, suggestion_id: suggestion.id)
  rescue Provider::Paperless::Error => e
    capture_error(e, "create")
    redirect_to review_card_path(@entry), alert: t(".failed")
  end

  private
    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection
      head :not_found unless @paperless_connection&.configured?
    end

    def receipt_search
      @receipt_search ||= PaperlessConnection::ReceiptSearch.new(@paperless_connection, @entry)
    end

    def default_query
      @entry.transaction.merchant&.name || @entry.name
    end

    def capture_error(error, action)
      capture_paperless_error(
        error, source: "#{self.class.name}##{action}", message: "Paperless receipt search failed", account: @entry.account,
        transaction_id: @entry.entryable_id, monthly_review_id: @monthly_review.id
      )
    end
end
