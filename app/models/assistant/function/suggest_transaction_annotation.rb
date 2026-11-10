# frozen_string_literal: true

class Assistant::Function::SuggestTransactionAnnotation < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

  MAX_HINT_LENGTH = 500

  class << self
    def name
      "suggest_transaction_annotation"
    end

    def description
      <<~INSTRUCTIONS
        Builds or returns the monthly review's proposal for one unreviewed
        transaction: a new name, merchant, category, tags and notes, and
        sometimes a split into parts. Changes nothing on the transaction; use
        apply_transaction_annotation with the returned suggestion_id to apply it.

        Without a hint it returns what the review card would show: the proposal
        read from the transaction's Paperless receipt (read now if it has not
        been read yet), else the category the family usually uses for this name
        ("learned", no AI call). With a hint (a short description from the user,
        e.g. "apple corer 12 + hand warmer 8") the AI builds the proposal from
        the hint plus the receipt, if any; the hint wins where they disagree.
        Item prices in the hint allow a split. The same receipt or hint is
        never read twice: a repeated call returns the stored proposal.

        Returns `status`:
        - "proposal": `changes` lists each field the proposal would change
          (current and proposed value; `selected_by_default` is what the review
          card pre-selects; `allowed: false` means this user may not change it).
          `split` lists the proposed parts when there is one.
        - "pending": the receipt is being read in the background. Call again in
          a minute.
        - "failed": reading failed; `error` says why.
        - "receipt_choice": several receipts match closely; the user picks one
          on the review card, or you pass a hint instead.
        - "no_proposal": nothing to propose.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "id" ],
      properties: {
        id: {
          type: "string",
          description: "Transaction id from get_monthly_review or get_transactions."
        },
        hint: {
          type: "string",
          description: "Optional short description of what was bought, in the user's words, ideally with item prices. Omit to use the receipt or the learned category."
        }
      }
    )
  end

  def call(params = {})
    entry, failure = find_review_entry(params["id"])
    return failure if failure
    return already_reviewed_error if entry.reviewed?

    hint = params["hint"].to_s.strip
    return error("invalid_hint", "The hint is longer than #{MAX_HINT_LENGTH} characters.") if hint.length > MAX_HINT_LENGTH

    review = MonthlyReview.find_or_build(family, entry.date)
    card = hint.present? ? card_for(review, entry, suggest_from_hint(entry, hint)) : default_card(review, entry)

    serialize(card)
  end

  private
    def suggester
      @suggester ||= Transaction::AnnotationSuggester.new(family, user: user)
    end

    def card_for(review, entry, suggestion = nil)
      MonthlyReview::Card.new(review, entry, user: user, suggestion_id: suggestion&.id)
    end

    # The card's own proposal; an unread receipt is read now and a failed
    # read is retried, as the card's "Read receipt" and "Retry" buttons do.
    def default_card(review, entry)
      card = card_for(review, entry)

      suggestion =
        case card.state
        when :unread then suggest_from_receipt(entry, card.receipt_link)
        when :failed then retry_suggestion(entry, card.suggestion)
        end

      suggestion ? card_for(review, entry, suggestion) : card
    end

    def retry_suggestion(entry, suggestion)
      if suggestion.hint? && suggestion.hint_text.present?
        suggest_from_hint(entry, suggestion.hint_text)
      elsif suggestion.receipt_link
        suggest_from_receipt(entry, suggestion.receipt_link)
      end
    end

    def suggest_from_receipt(entry, receipt_link)
      suggester.request_suggestion(entry, receipt_link: receipt_link)
    end

    def suggest_from_hint(entry, hint)
      suggester.request_suggestion(entry, hint: hint)
    end

    def serialize(card)
      entry = card.entry
      result = {
        success: true,
        status: status_for(card),
        transaction: serialize_transaction(entry)
      }

      if (suggestion = card.suggestion) && result[:status] != "no_proposal"
        result[:suggestion_id] = suggestion.id
        result[:source] = suggestion.source
        result[:hint] = card.hint_text if card.hint_text
      end

      if (link = card.receipt_link)
        result[:receipt] = { title: link.document_title, correspondent: link.document_correspondent, linked: link.linked? }.compact
      end

      case result[:status]
      when "proposal" then result.merge!(serialize_proposal(card))
      when "failed" then result[:error] = card.suggestion&.error.presence || "The proposal could not be built."
      when "receipt_choice"
        result[:receipt_candidates] = card.receipt_candidates.map do |link|
          { title: link.document_title, correspondent: link.document_correspondent, score: link.score&.to_f }.compact
        end
      when "no_proposal"
        result[:message] = card.reading_unavailable? ? "The receipt can't be read: no Paperless connection or AI provider is configured." : "Nothing to propose. Pass a hint, or mark it reviewed as it is."
      end

      result
    end

    def status_for(card)
      case card.state
      when :proposal then card.changes? ? "proposal" : "no_proposal"
      when :loading then "pending"
      when :failed then "failed"
      when :receipt_choice then "receipt_choice"
      else "no_proposal"
      end
    end

    def serialize_proposal(card)
      changes = card.fields.reject { |field| field.status == :unchanged }.map do |field|
        change = {
          field: field.key,
          current: present_value(field.current),
          proposed: present_value(field.proposed),
          selected_by_default: field.checked,
          allowed: field.change?
        }
        change[:new_merchant] = true if field.proposed.is_a?(MonthlyReview::Card::NewMerchant)
        change
      end

      proposal = {
        changes: changes,
        confidence: card.confidence,
        rationale: card.rationale
      }.compact
      proposal[:receipt_amount_mismatch] = true if card.receipt_mismatch?
      proposal[:learned] = true if card.learned?

      if card.split_parts.any?
        proposal[:split] = card.split_parts.map { |part| { name: part.name, amount: part.amount.format, category: part.category&.name }.compact }
        proposal[:split_allowed] = card.split_selectable?
        proposal[:split_selected_by_default] = card.split_checked?
      end

      proposal
    end

    def present_value(value)
      case value
      when nil, String then value
      when Array then value.map(&:name)
      else value.name
      end
    end
end
