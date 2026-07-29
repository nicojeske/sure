# frozen_string_literal: true

class ReceiptLinksController < ApplicationController
  include ActionView::RecordIdentifier

  before_action :set_entry
  before_action :set_receipt_link, only: %i[destroy confirm dismiss]

  def index
    load_receipt_links
  end

  def confirm
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @receipt_link.update!(status: "linked")
    render_receipt_links
  end

  def dismiss
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @receipt_link.update!(status: "dismissed")
    render_receipt_links
  end

  def destroy
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @receipt_link.destroy!
    render_receipt_links
  end

  private
    def set_entry
      @entry = Current.accessible_entries.find(params[:transaction_id])
    end

    def set_receipt_link
      @receipt_link = @entry.transaction.receipt_links.find(params[:id])
    end

    def load_receipt_links
      @receipt_links = @entry.transaction.receipt_links.ordered
    end

    def render_receipt_links
      load_receipt_links

      render turbo_stream: turbo_stream.replace(
        dom_id(@entry.transaction, :receipt_links),
        partial: "receipt_links/index"
      )
    end
end
