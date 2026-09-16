# frozen_string_literal: true

# Manual linking modal reached from the /receipts "Unmatched" tab: picks a transaction for one
# Paperless document, either from the DocumentMatcher's best candidates or a plain search — the
# reverse of ReceiptLinksController's manual search modal (which picks a document for one
# already-known transaction).
class Receipts::DocumentLinksController < ApplicationController
  include UnmatchedDocumentsListing

  # Kept small and local rather than reusing ReceiptLinksController's page size (25): this list
  # renders inside a modal alongside the candidates section, not as the modal's only content.
  SEARCH_PAGE_SIZE = 10

  before_action :set_paperless_connection
  before_action :require_connection

  def new
    @document_id = params[:document_id].to_s
    load_document
    load_candidates
    load_search_results
  end

  def create
    entry = Current.accessible_entries.find(params[:entry_id])
    return unless require_account_permission!(entry.account, :annotate, redirect_path: receipts_path(status: "unmatched"))

    link_document(entry.transaction)

    load_unmatched_documents
    render turbo_stream: [
      turbo_stream.replace("modal", view_context.turbo_frame_tag("modal")),
      turbo_stream.replace("receipts_list", partial: "receipts/unmatched_list")
    ]
  end

  private
    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection
    end

    def require_connection
      head :not_found if @paperless_connection.nil? || !@paperless_connection.configured?
    end

    def load_document
      @document = provider.document(params[:document_id])
      @correspondents = provider.correspondents
      @facts = facts_builder.for(@document)
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "Receipts::DocumentLinksController#new")
      @document = nil
      @correspondents = {}
      @facts = nil
      @load_error_message = t(".errors.#{UnmatchedDocumentsListing::ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}")
    end

    def load_candidates
      @candidates = @document.present? ? PaperlessConnection::DocumentMatcher.new(@paperless_connection).candidates_for(@document) : []
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "Receipts::DocumentLinksController#new")
      @candidates = []
    end

    # Defaults the query to the document's correspondent and the date range to the document's date
    # ± the connection's sweep window — the same window DocumentMatcher itself searches — so the
    # first render already shows the transactions most likely to be the right one, without the
    # user typing anything.
    def load_search_results
      @query = params[:q].presence || (@document.present? ? provider.correspondents[@document["correspondent"]] : nil)
      @page = params[:page].presence&.to_i || 1

      filters = { search: @query }.compact
      document_date = @document.present? ? ReceiptLink.parse_document_date(@document["created"]) : nil
      if document_date
        window = @paperless_connection.sweep_window_days
        filters[:start_date] = (document_date - window.days).to_s
        filters[:end_date] = (document_date + window.days).to_s
      end

      accessible_account_ids = Current.user.accessible_accounts.pluck(:id)
      search = Transaction::Search.new(Current.family, filters: filters, accessible_account_ids: accessible_account_ids)
      scope = search.transactions_scope.reverse_chronological.includes(:merchant, entry: :account)

      transactions = scope.offset((@page - 1) * SEARCH_PAGE_SIZE).limit(SEARCH_PAGE_SIZE + 1).to_a
      @search_next_page = transactions.size > SEARCH_PAGE_SIZE ? @page + 1 : nil
      @transactions = transactions.first(SEARCH_PAGE_SIZE)
    end

    def link_document(transaction)
      document = provider.document(params[:document_id])

      link = ReceiptLink.find_or_initialize_by(
        transaction_record: transaction,
        paperless_connection: @paperless_connection,
        document_id: document["id"]
      )
      link.status = "linked"
      link.source = "manual"
      link.apply_document_metadata(
        document,
        correspondent_name: provider.correspondents[document["correspondent"]],
        facts: facts_builder.for(document)
      )
      link.save!
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "Receipts::DocumentLinksController#create")
    end
end
