# frozen_string_literal: true

class PaperlessConnection::Matcher
  include PaperlessConnection::Scoring

  Candidate = Data.define(:document, :score, :reasons)

  # What `match!` actually persisted, so a caller scanning many transactions can tally outcomes
  # without re-querying receipt_links per transaction. :none covers "scanned, nothing worth
  # showing" — the receipt_scanned_at stamp still happens.
  Result = Data.define(:outcome, :candidates) # outcome: :linked | :suggested | :none

  SEARCH_PAGE_SIZE = 50

  attr_reader :connection

  def initialize(connection)
    @connection = connection
  end

  # Pure — issues one or two search requests, scores every result locally, no writes.
  def candidates_for(transaction)
    entry = transaction.entry
    return [] if entry.nil?

    window = connection.match_window_days

    documents = provider.search_documents(
      created_from: entry.date - window.days,
      created_to: entry.date + window.days,
      page_size: SEARCH_PAGE_SIZE,
      ordering: "-created"
    )["results"] || []

    documents = merge_documents(documents, structured_amount_documents(entry))

    documents.filter_map do |document|
      score, reasons = score_document(document, transaction, entry, window)
      next if score <= 0

      Candidate.new(document: document, score: score, reasons: reasons)
    end.sort_by { |candidate| -candidate.score }
  end

  # Persists links/suggestions per the decision table and always stamps receipt_scanned_at,
  # including when zero candidates are found. A candidate whose mapped total conflicts with the
  # transaction amount never auto-links, even if it otherwise clears the threshold on date +
  # correspondent alone — it still competes for a suggestion slot below. Returns a Result so
  # callers can tally outcomes.
  def match!(transaction)
    candidates = candidates_for(transaction)
    qualifying = candidates.select do |candidate|
      candidate.score >= connection.min_auto_link_score.to_f && !candidate.reasons["amount_conflict"]
    end

    outcome =
      case qualifying.size
      when 0
        suggestions = candidates.select { |candidate| candidate.score >= SUGGESTION_FLOOR }
          .first(MAX_SUGGESTIONS)
        suggestions.each { |candidate| persist_candidate(transaction, candidate, status: "suggested", source: "auto") }
        suggestions.any? ? :suggested : :none
      when 1
        persist_candidate(transaction, qualifying.first, status: "linked", source: "auto")
        :linked
      else
        qualifying.each { |candidate| persist_candidate(transaction, candidate, status: "suggested", source: "auto") }
        :suggested
      end

    transaction.update_column(:receipt_scanned_at, Time.current)
    Result.new(outcome: outcome, candidates: candidates)
  end

  private

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: connection.base_url,
        api_token: connection.api_token,
        verify_ssl: connection.verify_ssl
      )
    end

    def correspondents
      @correspondents ||= provider.correspondents
    end

    # Skipped entirely when the connection has no field mapped — the common case for a family
    # that hasn't set up Paperless custom fields — so the OCR-only path never pays for an extra
    # request.
    def custom_fields
      @custom_fields ||= any_field_mapped? ? provider.custom_fields : {}
    end

    def any_field_mapped?
      [
        connection.total_amount_field_id, connection.net_amount_field_id,
        connection.tax_amount_field_id, connection.reference_field_id
      ].any?
    end

    def document_facts
      @document_facts ||= PaperlessConnection::DocumentFacts.new(connection, custom_fields)
    end

    # Merges the date-window search with the amount-targeted one, first occurrence winning, keyed
    # by document id.
    def merge_documents(primary, secondary)
      return primary if secondary.empty?

      by_id = primary.index_by { |document| document["id"] }
      secondary.each { |document| by_id[document["id"]] ||= document }
      by_id.values
    end

    # A second search over a wider window, targeted at documents whose mapped total/net/tax field
    # exactly matches the transaction amount — catches invoices dated away from their payment date,
    # which the primary date-window search would otherwise miss entirely. Skipped when no monetary
    # field is mapped, or the transaction has no amount to search for.
    def structured_amount_documents(entry)
      field_names = mapped_monetary_field_names
      return [] if field_names.empty? || entry.amount.abs.zero?

      window = connection.structured_match_window_days
      value = "#{entry.currency}#{format('%.2f', entry.amount.abs)}"
      query = [ "OR", field_names.map { |name| [ name, "exact", value ] } ]

      provider.search_documents(
        created_from: entry.date - window.days,
        created_to: entry.date + window.days,
        page_size: SEARCH_PAGE_SIZE,
        ordering: "-created",
        custom_field_query: query
      )["results"] || []
    end

    def mapped_monetary_field_names
      [ connection.total_amount_field_id, connection.net_amount_field_id, connection.tax_amount_field_id ]
        .compact
        .filter_map { |id| custom_fields.dig(id, "name") }
    end

    # Thin adapter from a Candidate (document + score + reasons) to the shared `persist_link`
    # (`PaperlessConnection::Scoring`), which both matching directions call.
    def persist_candidate(transaction, candidate, status:, source:)
      persist_link(transaction, candidate.document, score: candidate.score, reasons: candidate.reasons, status: status, source: source)
    end
end
