# frozen_string_literal: true

class ReceiptLinksController < ApplicationController
  include ActionView::RecordIdentifier

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
      turbo_stream.replace("modal", view_context.turbo_frame_tag("modal"))
    ]
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

    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection
      head :not_found if @paperless_connection.nil? || !@paperless_connection.configured?
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

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: @paperless_connection.base_url,
        api_token: @paperless_connection.api_token,
        verify_ssl: @paperless_connection.verify_ssl
      )
    end

    def load_search_results
      response = provider.search_documents(query: @query, page: @page, page_size: 25, ordering: "-created")
      @documents = response["results"] || []
      @next_page = response["next"].present? ? @page + 1 : nil
      @correspondents = provider.correspondents
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "ReceiptLinksController#new")
      @documents = []
      @next_page = nil
      @correspondents = {}
      @search_error_message = t(".errors.#{ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}")
    end

    def link_document(document_id)
      return if document_id.blank?

      document = provider.document(document_id)

      link = ReceiptLink.find_or_initialize_by(
        transaction_record: @entry.transaction,
        paperless_connection: @paperless_connection,
        document_id: document["id"]
      )
      link.assign_attributes(
        status: "linked",
        source: "manual",
        document_title: document["title"],
        document_created_on: parse_document_date(document["created"]),
        document_correspondent: provider.correspondents[document["correspondent"]],
        document_mime_type: document["mime_type"]
      )
      link.save!
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "ReceiptLinksController#create")
    end

    def parse_document_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def capture_paperless_error(error, source:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless search failed: #{error.message}",
        source: source,
        provider_key: "paperless",
        family: Current.family,
        metadata: { error_type: error.error_type, transaction_id: @entry.transaction_id }
      )
    end
end
