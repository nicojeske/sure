# frozen_string_literal: true

# Amount/date/correspondent scoring shared by both matching directions:
# `PaperlessConnection::Matcher` (transaction → candidate documents) and
# `PaperlessConnection::DocumentMatcher` (document → candidate transactions). Extracted so the two
# directions can never drift on what "a good match" means — every method here takes the same
# `(document, transaction, entry, window)` shape regardless of which side initiated the search.
#
# Including classes must provide two private hooks:
#   - `document_facts` -> a `PaperlessConnection::DocumentFacts` instance (memoized per instance)
#   - `correspondents` -> `{ paperless_correspondent_id => name }` (memoized per instance)
# and `persist_link` reads `connection` from the including class.
module PaperlessConnection::Scoring
  extend ActiveSupport::Concern

  SUGGESTION_FLOOR = 0.40
  MAX_SUGGESTIONS  = 5

  # A structured total from the document's mapped custom field is stronger evidence than an OCR
  # regex hit; a match on the secondary (net/tax) field is weaker than either. A structured total
  # that's present but matches nothing scores 0 for amount and is flagged as a conflict (see
  # `#score_document`), which keeps it out of auto-linking without hiding it from suggestions.
  STRUCTURED_AMOUNT_WEIGHT           = 0.55
  OCR_AMOUNT_WEIGHT                  = 0.45
  STRUCTURED_SECONDARY_AMOUNT_WEIGHT = 0.30
  DATE_WEIGHT                        = 0.25
  CORRESPONDENT_WEIGHT               = 0.20

  private
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

    # Shared by both directions' `persist_link` — the single place a document gets attached to a
    # transaction via auto-matching. Refuses to overwrite an existing `linked` or `dismissed`
    # decision: a human's prior call on this pairing always wins over a re-run.
    def persist_link(transaction, document, score:, reasons:, status:, source:)
      link = ReceiptLink.find_or_initialize_by(
        transaction_record: transaction,
        paperless_connection: connection,
        document_id: document["id"]
      )

      return if link.persisted? && link.status.in?(%w[linked dismissed])

      link.status = status
      link.source = source
      link.score = score
      link.match_reasons = reasons
      link.apply_document_metadata(
        document,
        correspondent_name: correspondents[document["correspondent"]],
        facts: document_facts.for(document)
      )
      link.save!
    end
end
