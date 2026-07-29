# frozen_string_literal: true

class PaperlessConnection::Matcher
  Candidate = Data.define(:document, :score, :reasons)

  SUGGESTION_FLOOR = 0.40
  MAX_SUGGESTIONS  = 5
  SEARCH_PAGE_SIZE = 50

  AMOUNT_WEIGHT       = 0.55
  DATE_WEIGHT         = 0.25
  CORRESPONDENT_WEIGHT = 0.20

  attr_reader :connection

  def initialize(connection)
    @connection = connection
  end

  # Pure — issues one search request, scores every result locally, no writes.
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

    documents.filter_map do |document|
      score, reasons = score_document(document, transaction, entry, window)
      next if score <= 0

      Candidate.new(document: document, score: score, reasons: reasons)
    end.sort_by { |candidate| -candidate.score }
  end

  # Persists links/suggestions per the decision table and always stamps receipt_scanned_at,
  # including when zero candidates are found.
  def match!(transaction)
    candidates = candidates_for(transaction)
    qualifying = candidates.select { |candidate| candidate.score >= connection.min_auto_link_score.to_f }

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

    def score_document(document, transaction, entry, window)
      reasons = {}
      score = 0.0

      if amount_matches?(document, entry)
        score += AMOUNT_WEIGHT
        reasons["amount"] = true
      end

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
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
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

      link.assign_attributes(
        status: status,
        source: source,
        score: candidate.score,
        match_reasons: candidate.reasons,
        document_title: document["title"],
        document_created_on: parse_document_date(document["created"]),
        document_correspondent: correspondents[document["correspondent"]],
        document_mime_type: document["mime_type"]
      )
      link.save!
    end
end
