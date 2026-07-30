# frozen_string_literal: true

class PaperlessConnection::Matcher
  Candidate = Data.define(:document, :score, :reasons)

  SUGGESTION_FLOOR = 0.40
  MAX_SUGGESTIONS  = 5
  SEARCH_PAGE_SIZE = 50

  # A structured total from the document's mapped custom field is stronger evidence than an OCR
  # regex hit; a match on the secondary (net/tax) field is weaker than either. A structured total
  # that's present but matches nothing scores 0 for amount and is flagged as a conflict (see
  # `#score_document`), which keeps it out of auto-linking without hiding it from suggestions.
  STRUCTURED_AMOUNT_WEIGHT           = 0.55
  OCR_AMOUNT_WEIGHT                  = 0.45
  STRUCTURED_SECONDARY_AMOUNT_WEIGHT = 0.30
  DATE_WEIGHT                        = 0.25
  CORRESPONDENT_WEIGHT               = 0.20

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
  # correspondent alone — it still competes for a suggestion slot below.
  def match!(transaction)
    candidates = candidates_for(transaction)
    qualifying = candidates.select do |candidate|
      candidate.score >= connection.min_auto_link_score.to_f && !candidate.reasons["amount_conflict"]
    end

    case qualifying.size
    when 0
      candidates.select { |candidate| candidate.score >= SUGGESTION_FLOOR }
        .first(MAX_SUGGESTIONS)
        .each { |candidate| persist_link(transaction, candidate, status: "suggested", source: "auto") }
    when 1
      persist_link(transaction, qualifying.first, status: "linked", source: "auto")
    else
      qualifying.each { |candidate| persist_link(transaction, candidate, status: "suggested", source: "auto") }
    end

    transaction.update_column(:receipt_scanned_at, Time.current)
    candidates
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

    def score_document(document, transaction, entry, window)
      reasons = {}
      score = 0.0

      amount_score, amount_reason = amount_score(document, entry)
      score += amount_score
      reasons[amount_reason] = true if amount_reason

      date_score = date_proximity_score(document, entry, window)
      if date_score > 0
        score += date_score
        reasons["date"] = true
      end

      correspondent_score = correspondent_similarity(document, transaction, entry)
      if correspondent_score > 0
        score += correspondent_score * CORRESPONDENT_WEIGHT
        reasons["correspondent"] = true
      end

      [ score.round(3), reasons ]
    end

    # Structured totals outrank the OCR guess when present. A mapped total that's present in the
    # same currency but matches neither the transaction amount nor the secondary (net/tax) fields
    # is treated as a conflict — explicit evidence *against* this being the right document — while
    # net/tax alone matching is treated as weaker corroborating evidence.
    def amount_score(document, entry)
      facts = document_facts.for(document)

      if same_amount?(facts.total, entry)
        return [ STRUCTURED_AMOUNT_WEIGHT, "amount" ]
      end

      if facts.total.present? && facts.total.currency.iso_code == entry.currency
        return [ 0.0, "amount_conflict" ] unless same_amount?(facts.net, entry) || same_amount?(facts.tax, entry)

        return [ STRUCTURED_SECONDARY_AMOUNT_WEIGHT, "amount_secondary" ]
      end

      return [ OCR_AMOUNT_WEIGHT, "amount" ] if amount_matches?(document, entry)

      [ 0.0, nil ]
    end

    def same_amount?(money, entry)
      return false if money.nil?

      money.currency.iso_code == entry.currency && money.amount.round(2) == entry.amount.abs.round(2)
    end

    # Vendor receipts render amounts however the vendor's locale dictates, not the family's
    # locale, so all four common renderings are tried against the OCR content.
    def amount_matches?(document, entry)
      content = normalized_content(document)
      return false if content.blank?

      amount_variants(entry.amount.abs).any? { |variant| content.match?(amount_regex(variant)) }
    end

    def normalized_content(document)
      document["content"].to_s.gsub(/\s/, "")
    end

    def amount_regex(variant)
      /(?<![\d.,])#{Regexp.escape(variant)}(?![\d])/
    end

    def amount_variants(amount)
      rounded = amount.round(2)
      whole = rounded.truncate.to_i.to_s
      fraction = format("%02d", ((rounded - rounded.truncate) * 100).round)
      grouped = whole.reverse.gsub(/(\d{3})(?=\d)/, '\1,').reverse

      [
        "#{whole}.#{fraction}",
        "#{whole},#{fraction}",
        "#{grouped}.#{fraction}",
        "#{grouped.tr(',', '.')},#{fraction}"
      ].uniq
    end

    def date_proximity_score(document, entry, window)
      document_date = parse_document_date(document["created"])
      return 0.0 if document_date.nil?

      delta_days = (document_date - entry.date).to_i.abs
      return 0.0 if delta_days > window

      DATE_WEIGHT * (1 - delta_days.to_f / (window + 1))
    end

    def parse_document_date(value)
      ReceiptLink.parse_document_date(value)
    end

    def correspondent_similarity(document, transaction, entry)
      correspondent_name = correspondents[document["correspondent"]]
      return 0.0 if correspondent_name.blank?

      names = [ transaction.merchant&.name, entry.name ].compact
      return 0.0 if names.empty?

      names.map { |name| jaccard_similarity(correspondent_name, name) }.max
    end

    def jaccard_similarity(a, b)
      tokens_a = tokenize(a)
      tokens_b = tokenize(b)
      return 0.0 if tokens_a.empty? || tokens_b.empty?

      union = (tokens_a | tokens_b).size
      return 0.0 if union.zero?

      (tokens_a & tokens_b).size.to_f / union
    end

    def tokenize(text)
      text.to_s.downcase.scan(/[a-z0-9]+/).uniq
    end

    def persist_link(transaction, candidate, status:, source:)
      document = candidate.document

      link = ReceiptLink.find_or_initialize_by(
        transaction_record: transaction,
        paperless_connection: connection,
        document_id: document["id"]
      )

      return if link.persisted? && link.status.in?(%w[linked dismissed])

      link.status = status
      link.source = source
      link.score = candidate.score
      link.match_reasons = candidate.reasons
      link.apply_document_metadata(
        document,
        correspondent_name: correspondents[document["correspondent"]],
        facts: document_facts.for(document)
      )
      link.save!
    end
end
