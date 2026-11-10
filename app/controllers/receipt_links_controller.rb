# frozen_string_literal: true

class ReceiptLinksController < ApplicationController
  include ActionView::RecordIdentifier
  include PaperlessErrorCapturing

  ERROR_TYPE_MESSAGE_KEYS = {
    unauthorized: :unauthorized,
    not_found: :not_found,
    rate_limited: :rate_limited,
    server_error: :server_error,
    unreachable: :unreachable,
    parse_error: :parse_error,
    untrusted_host: :untrusted_host,
    unknown: :unknown
  }.freeze

  before_action :set_entry
  before_action :set_receipt_link, only: %i[destroy confirm dismiss]
  before_action :set_paperless_connection, only: %i[new create]

  def index
    load_receipt_links
    trigger_auto_link_scan
  end

  def new
    @query = params[:q].presence || @entry.transaction.merchant&.name || @entry.name
    @page = params[:page].presence&.to_i || 1
    load_search_results
  end

  def create
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    link_document(params[:document_id])
    load_receipt_links

    render turbo_stream: [
      turbo_stream.replace(dom_id(@entry.transaction, :receipt_links), partial: "receipt_links/index"),
      turbo_stream.replace("modal", view_context.turbo_frame_tag("modal")),
      *receipt_pill_streams
    ]
  end

  def confirm
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @receipt_link.confirm!
    render_receipt_links
  end

  def dismiss
    return unless require_account_permission!(@entry.account, :annotate, redirect_path: transaction_path(@entry))

    @receipt_link.dismiss!
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

    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection
      head :not_found if @paperless_connection.nil? || !@paperless_connection.configured?
    end

    def load_receipt_links
      @receipt_links = @entry.transaction.receipt_links.ordered
    end

    def trigger_auto_link_scan
      return if @entry.transaction.receipt_scanned_at.present?

      connection = Current.family.paperless_connection
      return unless connection&.configured? && connection.auto_link_enabled?

      @scanning = true
      PaperlessAutoLinkJob.perform_later(@entry.transaction.id)
    end

    def render_receipt_links
      load_receipt_links

      render turbo_stream: [
        turbo_stream.replace(dom_id(@entry.transaction, :receipt_links), partial: "receipt_links/index"),
        *receipt_pill_streams
      ]
    end

    # Refreshes the row's receipt pill (see transactions/_receipt_pill) alongside the drawer's
    # receipt_links frame — the pill lives outside that frame, in the transactions list, so it
    # would otherwise stay stale until a full page reload. Harmless no-op when the mutation
    # didn't touch linked state (e.g. dismissing a suggestion). A split parent's children show
    # its receipt, so their pills are refreshed too.
    def receipt_pill_streams
      transaction = @entry.transaction
      link = @receipt_links.detect(&:linked?)

      own = turbo_stream.replace(
        dom_id(transaction, :receipt_pill),
        partial: "transactions/receipt_pill",
        locals: { transaction: transaction, receipt_link: link, conflict: link&.amount_conflicts_with?(@entry) }
      )

      children = @entry.child_entries.includes(:entryable).map(&:entryable).map do |child|
        turbo_stream.replace(dom_id(child, :receipt_pill), partial: "transactions/receipt_pill", locals: { transaction: child })
      end

      [ own, *children ]
    end

    def receipt_search
      @receipt_search ||= PaperlessConnection::ReceiptSearch.new(@paperless_connection, @entry)
    end

    def load_search_results
      result = receipt_search.search(query: @query, page: @page)
      @documents = result.documents
      @next_page = result.next_page
      @correspondents = result.correspondents
      @document_facts = result.facts
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "ReceiptLinksController#new", message: "Paperless search failed", transaction_id: @entry.transaction_id)
      @documents = []
      @next_page = nil
      @correspondents = {}
      @document_facts = {}
      @search_error_message = t(".errors.#{ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}")
    end

    def link_document(document_id)
      return if document_id.blank?

      receipt_search.link!(document_id)
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "ReceiptLinksController#create", message: "Paperless search failed", transaction_id: @entry.transaction_id)
    end
end
