# frozen_string_literal: true

# The reverse of `PaperlessConnection::Matcher`: given one Paperless document, finds and scores
# candidate transactions locally (no Paperless API calls beyond the memoized correspondents/
# custom_fields lookups) and persists ReceiptLinks with the same decision table. Built for
# `PaperlessSweepDocumentsJob`, which walks Paperless's documents (newest-added first) instead of
# walking transactions — the only way a backlog of historical receipts, uploaded to Paperless long
# after the transactions they belong to, ever gets matched.
class PaperlessConnection::DocumentMatcher
  include PaperlessConnection::Scoring

  Candidate = Data.define(:transaction, :score, :reasons)

  # What `match!` actually persisted, mirroring `PaperlessConnection::Matcher::Result`.
  Result = Data.define(:outcome, :candidates) # outcome: :linked | :suggested | :none

  # A safety net on the "no structured total" branch, where the candidate set is an entire date
  # window rather than an exact-amount match — see `#candidate_transactions`.
  MAX_CANDIDATE_TRANSACTIONS = 400

  attr_reader :connection

  def initialize(connection)
    @connection = connection
  end

  # Pure — no writes, no receipt_scanned_at stamp. Unlike the forward matcher, a transaction with
  # no amount signal at all is never returned: date + correspondent alone (up to 0.45) would clear
  # SUGGESTION_FLOOR and bury every document under every nearby transaction, which is meaningless
  # noise in this direction (there's no single "this document's transaction" without an amount
  # hit). This also drops `amount_conflict` candidates for free, since that branch never sets the
  # "amount" or "amount_secondary" reason — a conflicting transaction is simply the wrong one, not
  # a weaker suggestion, unlike the symmetric case on the forward matcher.
  def candidates_for(document)
    document_date = parse_document_date(document["created"])
    return [] if document_date.nil?

    window = connection.sweep_window_days

    candidate_transactions(document, document_date, window).filter_map do |transaction|
      entry = transaction.entry
      next if entry.nil?

      score, reasons = score_document(document, transaction, entry, window)
      next if score <= 0
      next unless reasons["amount"] || reasons["amount_secondary"]

      Candidate.new(transaction: transaction, score: score, reasons: reasons)
    end.sort_by { |candidate| -candidate.score }
  end

  # Same decision table as `Matcher#match!`, just persisting the other side of the relationship.
  # Deliberately does NOT touch `transaction.receipt_scanned_at` — that column means "the
  # transaction-side scan has looked at this transaction", and a document sweep only ever looks at
  # transactions inside one document's date window, never all of a transaction's candidates. Setting
  # it here would incorrectly suppress the forward scan for transactions this sweep never fully
  # examined.
  def match!(document)
    candidates = candidates_for(document)
    qualifying = candidates.select do |candidate|
      candidate.score >= connection.min_auto_link_score.to_f && !candidate.reasons["amount_conflict"]
    end

    outcome =
      case qualifying.size
      when 0
        suggestions = candidates.select { |candidate| candidate.score >= SUGGESTION_FLOOR }
          .first(MAX_SUGGESTIONS)
        suggestions.each { |candidate| persist_candidate(candidate, document, status: "suggested") }
        suggestions.any? ? :suggested : :none
      when 1
        persist_candidate(qualifying.first, document, status: "linked")
        :linked
      else
        qualifying.each { |candidate| persist_candidate(candidate, document, status: "suggested") }
        :suggested
      end

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

    # Skipped entirely when the connection has no field mapped, same as the forward matcher.
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

    # When the document has a mapped, parseable total, narrow to transactions with that exact
    # amount and currency — the common case becomes a handful of rows, and it mirrors the forward
    # matcher's semantics where a mismatched total is a conflict, not a weaker candidate, so a
    # transaction with a different amount is never even considered here. Otherwise, fall back to
    # the whole date window and let `score_document`'s OCR regex do the filtering.
    def candidate_transactions(document, document_date, window)
      base = connection.family.transactions
        .joins(:entry)
        .includes(:merchant, entry: :account)
        .where.not(kind: Transaction::TRANSFER_KINDS)
        .where(entries: { date: (document_date - window.days)..(document_date + window.days) })

      total = document_facts.for(document).total
      if total.present?
        base.where(entries: { currency: total.currency.iso_code })
          .where("ABS(entries.amount) = ?", total.amount)
          .limit(MAX_CANDIDATE_TRANSACTIONS)
      else
        base.limit(MAX_CANDIDATE_TRANSACTIONS)
      end
    end

    def persist_candidate(candidate, document, status:)
      persist_link(candidate.transaction, document, score: candidate.score, reasons: candidate.reasons, status: status, source: "auto")
    end
end
