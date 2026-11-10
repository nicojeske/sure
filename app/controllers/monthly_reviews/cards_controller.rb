# The monthly review card: one transaction at a time with its proposal, the
# month's list beside it, and the decisions that move through the queue.
# The card lives in the "monthly_review_card" Turbo frame; every decision
# redirects to the card to show next.
class MonthlyReviews::CardsController < ApplicationController
  include MonthlyReviewScoped

  before_action :set_entry, only: :update

  def show
    @monthly_review.prefetch_suggestions_later(Current.user, include_transfers: include_transfers?) unless turbo_frame_request?
    set_review_breadcrumbs([ t("breadcrumbs.monthly_review_cards"), nil ])

    @list = @monthly_review.card_list(Current.annotatable_entries, include_transfers: include_transfers?)
    @entry = @list.current_entry(entry_id: params[:entry_id], finished: params[:finished].present?)
    return unless @entry

    @card = MonthlyReview::Card.new(@monthly_review, @entry, user: Current.user, suggestion_id: params[:suggestion_id])
    @card.read_receipt_later!

    @next_entry = @list.next_unreviewed_after(@entry)
    @monthly_review.read_receipt_later(@next_entry, Current.user) if @next_entry
  end

  def update
    case params[:decision]
    when "accept" then accept!
    when "reviewed_only" then reviewed_only!
    when "skip" then redirect_to_next
    when "back" then back!
    when "undo" then undo!
    when "suggest" then suggest!
    when "edit" then edit!
    else head :unprocessable_entity
    end
  rescue TransactionAnnotationSuggestion::Applier::Error, ActiveRecord::RecordInvalid
    redirect_to review_card_path(@entry), alert: t(".failed")
  end

  private
    # Accepting a card that is already reviewed only moves on, so its review
    # (and what undo reverts) stays as it was.
    def accept!
      unless @entry.reviewed?
        suggestion = @entry.annotation_suggestions.find_by(id: params[:suggestion_id]) if params[:suggestion_id].present?

        if suggestion&.applicable?
          suggestion.apply!(user: Current.user, fields: Array(params[:fields]), split: params[:split] == "1")
        else
          @entry.mark_reviewed!(Current.user)
        end
      end
      redirect_to_next
    end

    def reviewed_only!
      @entry.mark_reviewed!(Current.user) unless @entry.reviewed?
      redirect_to_next
    end

    def back!
      previous = @monthly_review.previous_entry_before(@entry, Current.annotatable_entries, include_transfers: include_transfers?)
      redirect_to review_card_path(previous || @entry)
    end

    def undo!
      redirect_to review_card_path(@monthly_review.undo_review!(@entry, Current.user))
    end

    # Reads a receipt of the entry on request: a failed or stale one, or a
    # close candidate the user picked.
    def suggest!
      link = @entry.transaction.receipt_links.where.not(status: "dismissed").find(params[:receipt_link_id])
      suggestion = suggest_unless_in_flight(Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: link)) do
        suggester.suggest_from_receipt(@entry, link)
      end

      redirect_to review_card_path(@entry, suggestion_id: suggestion.id)
    end

    def edit!
      unless @entry.reviewed?
        proposal = @entry.annotation_suggestions.find_by(id: params[:suggestion_id]) if params[:suggestion_id].present?
        MonthlyReview::ManualEdit.new(@entry, user: Current.user, proposal: proposal).save!(edit_params)
      end
      redirect_to_next
    end

    def redirect_to_next
      next_entry = @monthly_review.next_entry_after(@entry, Current.annotatable_entries, include_transfers: include_transfers?)
      redirect_to next_entry ? review_card_path(next_entry) : review_card_path(finished: 1)
    end

    def edit_params
      params.require(:entry).permit(:name, :notes, entryable_attributes: [ :category_id, :merchant_id, { tag_ids: [] } ])
    end
end
