# frozen_string_literal: true

# The manual "find a receipt for this transaction" search, shared by the
# transaction drawer (ReceiptLinksController) and the monthly review card
# (MonthlyReviews::ReceiptSearchesController): search Paperless, read each
# document's mapped amount, put the documents whose total equals the
# transaction first, and link the one the user picks.
#
# Raises Provider::Paperless::Error; callers decide how to show and log it.
class PaperlessConnection::ReceiptSearch
  PAGE_SIZE = 25

  Result = Data.define(:documents, :next_page, :correspondents, :facts)

  attr_reader :connection, :entry

  def initialize(connection, entry)
    @connection = connection
    @entry = entry
  end

  def search(query:, page: 1, created_from: nil, created_to: nil)
    response = provider.search_documents(
      query: query, page: page, page_size: PAGE_SIZE, ordering: "-created", created_from: created_from, created_to: created_to
    )
    documents = response["results"] || []
    facts = documents.index_by { |document| document["id"] }.transform_values { |document| facts_builder.for(document) }

    Result.new(
      documents: sort_by_amount_match(documents, facts),
      next_page: response["next"].present? ? page + 1 : nil,
      correspondents: provider.correspondents,
      facts: facts
    )
  end

  # Links the document to the entry's transaction as the user's choice and
  # caches its metadata on the link.
  def link!(document_id)
    document = provider.document(document_id)

    link = ReceiptLink.find_or_initialize_by(
      transaction_record: entry.transaction,
      paperless_connection: connection,
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
    link
  end

  private
    def provider
      @provider ||= Provider::Paperless.new(
        base_url: connection.base_url,
        api_token: connection.api_token,
        verify_ssl: connection.verify_ssl
      )
    end

    # Stable-sorts documents whose mapped total matches the transaction amount to the front,
    # without removing anything from the list — a document with no custom fields keeps its place.
    def sort_by_amount_match(documents, facts)
      documents.sort_by.with_index { |document, index| [ same_amount?(facts[document["id"]]&.total) ? 0 : 1, index ] }
    end

    def same_amount?(total)
      total.present? && total.currency.iso_code == entry.currency && total.amount.round(2) == entry.amount.abs.round(2)
    end

    def facts_builder
      @facts_builder ||= PaperlessConnection::DocumentFacts.new(connection, custom_fields)
    end

    # Skipped entirely when the connection has no field mapped, so a search or link never pays
    # for an extra request in the common case where Paperless custom fields aren't configured.
    def custom_fields
      return {} unless any_field_mapped?

      provider.custom_fields
    end

    def any_field_mapped?
      [
        connection.total_amount_field_id, connection.net_amount_field_id,
        connection.tax_amount_field_id, connection.reference_field_id
      ].any?
    end
end
