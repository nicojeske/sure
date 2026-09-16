# frozen_string_literal: true

# Shared loading for "documents this family hasn't linked to a transaction yet" — used by the
# "Unmatched" tab (ReceiptsController#index) and by the manual document-linking modal
# (Receipts::DocumentLinksController), so both read Paperless documents, resolve correspondents/
# structured facts, and report provider errors the same way. Requires the including controller to
# set `@paperless_connection` before calling anything here (e.g. via ReceiptLinkListing's
# `set_paperless_connection`, or its own equivalent).
module UnmatchedDocumentsListing
  extend ActiveSupport::Concern

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

  # Search results carry the full OCR `content` field, so a smaller page than the provider's
  # default keeps individual responses reasonable — matches PaperlessSweepDocumentsJob's page size.
  UNMATCHED_PAGE_SIZE = 50

  private
    def load_unmatched_documents
      @page = params[:page].presence&.to_i || 1
      return if @paperless_connection.nil?

      linked_document_ids = @paperless_connection.receipt_links.linked.distinct.pluck(:document_id).to_set
      response = provider.search_documents(page: @page, page_size: UNMATCHED_PAGE_SIZE, ordering: "-added")
      documents = response["results"] || []

      # Filtered client-side, so a page can show fewer than UNMATCHED_PAGE_SIZE rows even though
      # `@unmatched_next_page` (from Paperless's own "next" link) says there's more — the count
      # Paperless reports includes documents this family has already linked.
      @unmatched_documents = documents.reject { |document| linked_document_ids.include?(document["id"]) }
      @unmatched_next_page = response["next"].present? ? @page + 1 : nil
      @correspondents = provider.correspondents
      @document_facts = @unmatched_documents.index_by { |document| document["id"] }
        .transform_values { |document| facts_builder.for(document) }
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "#{self.class.name}#load_unmatched_documents")
      @unmatched_documents = []
      @unmatched_next_page = nil
      @correspondents = {}
      @document_facts = {}
      @unmatched_error_message = t("receipts.index.unmatched_errors.#{ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}")
    end

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: @paperless_connection.base_url,
        api_token: @paperless_connection.api_token,
        verify_ssl: @paperless_connection.verify_ssl
      )
    end

    # Named distinctly from the `@document_facts` ivar the view reads (a { document_id => Facts }
    # hash) — this is the PaperlessConnection::DocumentFacts service object itself, memoized so
    # custom_fields is only looked up once per request. Mirrors ReceiptLinksController exactly.
    def facts_builder
      @facts_builder ||= PaperlessConnection::DocumentFacts.new(@paperless_connection, custom_fields)
    end

    # Skipped entirely when the connection has no field mapped, so listing/linking a document
    # never pays for an extra request in the common case where Paperless custom fields aren't
    # configured.
    def custom_fields
      return {} unless any_field_mapped?

      provider.custom_fields
    end

    def any_field_mapped?
      [
        @paperless_connection.total_amount_field_id, @paperless_connection.net_amount_field_id,
        @paperless_connection.tax_amount_field_id, @paperless_connection.reference_field_id
      ].any?
    end

    def capture_paperless_error(error, source:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless search failed: #{error.message}",
        source: source,
        provider_key: "paperless",
        family: Current.family,
        metadata: { error_type: error.error_type }
      )
    end
end
