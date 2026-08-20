# frozen_string_literal: true

# Confirm / dismiss / unlink a match straight from the /receipts list, so reviewing a batch of
# suggestions doesn't mean opening each transaction's drawer in turn.
#
# Each action re-renders the whole list rather than just the touched row: the decision usually
# moves the row out of the active status filter (confirming while viewing "Suggested"), so
# replacing the row in place would leave a linked row sitting in a suggested-only list.
class Receipts::LinksController < ApplicationController
  include ReceiptLinkListing

  before_action :set_paperless_connection
  before_action :require_connection
  before_action :set_list_filters
  before_action :set_receipt_link

  def confirm
    return unless authorized?

    @receipt_link.confirm!
    render_list
  end

  def dismiss
    return unless authorized?

    @receipt_link.dismiss!
    render_list
  end

  def destroy
    return unless authorized?

    @receipt_link.destroy!
    render_list
  end

  private
    def require_connection
      head :not_found if @paperless_connection.nil?
    end

    def set_receipt_link
      @receipt_link = accessible_receipt_links.find(params[:id])
    end

    def authorized?
      require_account_permission!(
        @receipt_link.transaction_record.entry.account,
        :annotate,
        redirect_path: receipts_path(list_filter_params)
      )
    end

    def render_list
      load_receipt_link_list

      respond_to do |format|
        format.turbo_stream { render turbo_stream: turbo_stream.replace("receipts_list", partial: "receipts/list") }
        format.html { redirect_to receipts_path(list_filter_params) }
      end
    end
end
