# Builds annotation proposals (name, merchant, category, tags, notes, split)
# for one transaction entry during the monthly review:
#
#   suggest_from_receipt -- from a Paperless receipt's OCR text (never the file)
#   suggest_from_hint    -- from a typed hint, plus the chosen receipt if any;
#                           the hint wins where they disagree
#   learned_suggestion   -- category only, from the family's history, no LLM
#
# Every proposal is stored as a TransactionAnnotationSuggestion keyed by its
# input, so the same receipt or hint never reaches the LLM twice. Provider
# output is normalized here: names resolve to this family's records, unknown
# categories and tags are dropped, a split survives only when it is safe to
# apply as-is, and fields a rule set are only proposed when a hint asks.
class Transaction::AnnotationSuggester
  Error = Class.new(StandardError)
  # The receipt cannot be used (wrong transaction or family, no OCR text);
  # the LLM is not involved.
  ReceiptError = Class.new(Error)

  MAX_RECEIPT_CHARS = 6_000
  MAX_EXAMPLES = 5
  MAX_MERCHANTS = 300
  # A suggested receipt is used without asking only when no other suggestion
  # scores within this margin of it.
  CLEAR_CUT_MARGIN = 0.15
  # A receipt total within the larger of these still counts as matching.
  AMOUNT_TOLERANCE_RATIO = BigDecimal("0.01")
  AMOUNT_TOLERANCE_MIN = BigDecimal("0.50")

  REDACTED = "[redacted]".freeze
  REDACTIONS = [
    /\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?\b/, # IBAN
    /\b\d(?:[ -]?\d){12,18}\b/, # card number
    /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, # email
    %r{(?:\+|\b00)\d{1,3}[ /().-]*\d(?:[ /().-]*\d){5,}}, # international phone
    %r{\b0\d{2,5}(?: ?[/-] ?| )\d{2,}(?:[ -]?\d+)*} # national phone with area code
  ].freeze

  # link: the receipt to read; candidates: close suggestions to choose from
  # when none is clear-cut (link is then nil).
  ReceiptChoice = Data.define(:link, :candidates)

  # Works on preloaded receipt_links without further queries.
  def self.receipt_choice(transaction)
    links = transaction.receipt_links.sort_by { |link| [ link.score ? 1 : 0, -link.score.to_f, -link.created_at.to_f ] }
    linked = links.find(&:linked?)
    return ReceiptChoice.new(link: linked, candidates: []) if linked

    suggested = links.select(&:suggested?)
    top, runner_up = suggested
    return ReceiptChoice.new(link: top, candidates: []) if runner_up.nil? || top.score.to_f - runner_up.score.to_f >= CLEAR_CUT_MARGIN

    ReceiptChoice.new(link: nil, candidates: suggested.select { |link| top.score.to_f - link.score.to_f < CLEAR_CUT_MARGIN })
  end

  # The input_hash a proposal from this receipt and/or hint is stored under.
  def self.input_hash(source, receipt_link: nil, hint: nil)
    TransactionAnnotationSuggestion.input_hash_for(source, [ receipt_link&.document_id, hint.presence ].compact.join("|"))
  end

  # Whether a suggestion failure points at the LLM provider rather than at
  # Paperless or the receipt itself.
  def self.llm_failure?(error)
    !error.is_a?(ReceiptError) && !error.is_a?(Provider::Paperless::Error)
  end

  def self.redact(text)
    REDACTIONS.reduce(text.to_s) { |redacted, pattern| redacted.gsub(pattern, REDACTED) }
  end

  def self.amount_tolerance(entry)
    [ AMOUNT_TOLERANCE_MIN, entry.amount.abs * AMOUNT_TOLERANCE_RATIO ].max
  end

  # The error behind the last failed suggestion this instance ran, if any.
  attr_reader :family, :user, :last_error

  def initialize(family, user:)
    @family = family
    @user = user
  end

  def suggest_from_receipt(entry, receipt_link)
    run(entry, source: :receipt, receipt_link: receipt_link, hint: nil)
  end

  def suggest_from_hint(entry, text)
    run(entry, **hint_input(entry, text))
  end

  # A proposal someone asked for: from `receipt_link`, or from `hint` (read
  # together with the transaction's chosen receipt). The input is claimed
  # first, so a run that another request or the background prefetch owns is
  # never started twice; its row comes back pending instead. A stored result
  # is returned as is, and a failed one is run again only with `retry_failed`.
  def request_suggestion(entry, receipt_link: nil, hint: nil, retry_failed: true)
    input = hint.nil? ? { source: :receipt, receipt_link: receipt_link, hint: nil } : hint_input(entry, hint)
    input_hash = self.class.input_hash(input[:source], receipt_link: input[:receipt_link], hint: input[:hint])
    claimed = TransactionAnnotationSuggestion.claim_for(
      entry, input_hash: input_hash, retry_failed: retry_failed, family: family, source: input[:source].to_s
    )

    claimed ? run(entry, **input) : entry.annotation_suggestions.find_by!(input_hash: input_hash)
  end

  # nil when the history has no answer or the answer is the current category.
  def learned_suggestion(entry)
    category_id, confidence = learned_category(entry)
    return nil if category_id.nil? || category_id == entry.transaction.category_id

    suggestion = TransactionAnnotationSuggestion.find_or_create_for!(
      entry,
      input_hash: TransactionAnnotationSuggestion.input_hash_for(:learned, "#{entry.name}|#{category_id}"),
      family: family, source: "learned"
    )
    return suggestion if suggestion.applied?

    suggestion.update!(
      family: family, source: "learned", status: "ready", error: nil,
      payload: { "category_id" => category_id, "confidence" => confidence&.round(3) }
    )
    suggestion
  end

  # The provider_key failures are logged under, e.g. "openai".
  def llm_provider_key
    llm_provider && llm_provider.class.name.demodulize.underscore
  end

  private
    # A hint is read together with the receipt the card would read.
    def hint_input(entry, text)
      { source: :hint, receipt_link: self.class.receipt_choice(entry.transaction).link, hint: text.to_s.strip }
    end

    def run(entry, source:, receipt_link:, hint:)
      @last_error = nil
      suggestion = TransactionAnnotationSuggestion.find_or_create_for!(
        entry,
        input_hash: self.class.input_hash(source, receipt_link: receipt_link, hint: hint),
        family: family, source: source.to_s
      )
      return suggestion if suggestion.ready? || suggestion.applied? || suggestion.reverted?

      suggestion.update!(family: family, source: source.to_s, hint_text: hint.presence, status: "pending", error: nil)

      begin
        if receipt_link
          verify_receipt_link!(entry, receipt_link)
          suggestion.update!(receipt_link: receipt_link)
        end

        rule_set_fields = MonthlyReview::RuleProvenance.new(family, [ entry ]).rule_set_fields(entry).keys
        payload = normalize(entry, request_annotation(entry, receipt_link, hint, rule_set_fields), receipt_link)
        payload = without_rule_set_proposals(payload, rule_set_fields) if hint.blank?
        suggestion.update!(status: "ready", payload: payload)
      rescue StandardError => e
        @last_error = e
        suggestion.update!(status: "failed", error: e.message.to_s.truncate(1_000))
        capture_failure(entry, suggestion, e)
      end

      suggestion
    end

    def verify_receipt_link!(entry, receipt_link)
      return if receipt_link.transaction_id == entry.entryable_id &&
        receipt_link.paperless_connection.family_id == family.id &&
        entry.account.family_id == family.id

      raise ReceiptError, "Receipt link #{receipt_link.id} does not belong to this transaction"
    end

    def llm_provider
      @llm_provider ||= Provider::Registry.preferred_llm_provider
    end

    def request_annotation(entry, receipt_link, hint, rule_set_fields)
      raise Error, "No LLM provider configured" unless llm_provider

      response = llm_provider.suggest_transaction_annotation(
        transaction: transaction_context(entry),
        receipt_text: receipt_link && receipt_text(receipt_link),
        hint: hint.presence,
        examples: examples_for(entry),
        categories: family.categories.alphabetically.pluck(:name),
        merchants: merchants.alphabetically.limit(MAX_MERCHANTS).pluck(:name),
        tags: family.tags.alphabetically.pluck(:name),
        locale: family.ai_interface_locale_for(user),
        content_locale: family.ai_content_locale_for(user),
        rule_set_fields: rule_set_fields,
        family: family
      )
      raise Error, "Provider failed: #{response.error&.message}" unless response.success?

      response.data
    end

    def receipt_text(receipt_link)
      content = receipt_link.paperless_connection.provider.document(receipt_link.document_id)["content"]
      raise ReceiptError, "Receipt #{receipt_link.document_id} has no OCR text" if content.blank?

      self.class.redact(content).first(MAX_RECEIPT_CHARS)
    end

    def transaction_context(entry)
      transaction = entry.transaction

      {
        date: entry.date.iso8601,
        amount: entry.amount.abs.to_s("F"),
        currency: entry.currency,
        direction: entry.amount.negative? ? "income" : "expense",
        name: entry.name,
        bank_text: transaction.extra&.dig("original_name"),
        merchant: transaction.merchant&.name,
        category: transaction.category&.name
      }.compact
    end

    def examples_for(entry)
      transaction = entry.transaction
      names = [ entry.name, transaction.extra&.dig("original_name") ].compact_blank.uniq
      match = Transaction.where(entries: { name: names })
        .or(Transaction.where("transactions.extra ->> 'original_name' IN (?)", names))
      match = match.or(Transaction.where(merchant_id: transaction.merchant_id)) if transaction.merchant_id

      accessible_transactions
        .merge(match)
        .merge(Entry.reviewed)
        .where.not(id: transaction.id)
        .includes(:category, :merchant, :tags, :entry)
        .reorder("entries.reviewed_at DESC")
        .limit(MAX_EXAMPLES)
        .map do |example|
          {
            name: example.entry.name,
            merchant: example.merchant&.name,
            category: example.category&.name,
            tags: example.tags.map(&:name),
            notes: example.entry.notes.presence
          }.compact
        end
    end

    def learned_category(entry)
      transaction = entry.transaction
      usual = accessible_transactions.where.not(id: transaction.id).name_suggestions_for_names([ entry.name ]).first&.category
      return [ usual.id, nil ] if usual

      Family::BayesCategorizer.new(family).classify(transaction)
    end

    # Only a hint may override what a rule set; the prompt says so too, and
    # this holds whatever the model returns.
    def without_rule_set_proposals(payload, rule_set_fields)
      rule_set_fields.each_with_object(payload.dup) do |field, kept|
        case field
        when "merchant" then kept.merge!("merchant_id" => nil, "new_merchant_name" => nil)
        when "tags" then kept["tag_ids"] = []
        else kept[TransactionAnnotationSuggestion::FIELD_ATTRIBUTES.fetch(field)] = nil
        end
      end
    end

    def normalize(entry, raw, receipt_link)
      mismatch = receipt_amount_mismatch?(entry, receipt_link, raw.receipt_total)
      merchant = resolve_merchant(raw.merchant_name)

      {
        "name" => raw.name,
        "notes" => raw.notes,
        "category_id" => resolve_category(raw.category_name)&.id,
        "merchant_id" => merchant&.id,
        "new_merchant_name" => merchant ? nil : raw.merchant_name,
        "tag_ids" => resolve_tag_ids(raw.tag_names),
        "confidence" => raw.confidence&.clamp(0.0, 1.0),
        "rationale" => raw.rationale,
        "receipt_amount_mismatch" => mismatch,
        "split" => mismatch ? nil : normalize_split(entry, raw.split)
      }
    end

    def receipt_amount_mismatch?(entry, receipt_link, receipt_total)
      return false unless receipt_link

      tolerance = self.class.amount_tolerance(entry)
      return true if receipt_link.amount_conflicts_with?(entry, tolerance: tolerance)

      receipt_total.present? && (BigDecimal(receipt_total.to_s) - entry.amount.abs).abs > tolerance
    end

    def normalize_split(entry, parts)
      return nil if parts.blank? || !entry.transaction.splittable?

      rows = parts.map do |part|
        {
          "name" => part.name,
          "amount" => part.amount && BigDecimal(part.amount.to_s),
          "category_id" => resolve_category(part.category_name)&.id,
          "tag_ids" => resolve_tag_ids(part.tag_names),
          "notes" => part.notes
        }
      end
      return nil if rows.size < 2 || rows.any? { |row| row["name"].blank? || row["amount"].nil? || !row["amount"].positive? }
      return nil if rows.filter_map { |row| row["category_id"] }.uniq.size < 2

      amounts = fit_amounts(rows.map { |row| row["amount"] }, entry.amount.abs, self.class.amount_tolerance(entry))
      return nil unless amounts

      sign = entry.amount.negative? ? -1 : 1
      rows.zip(amounts).map { |row, amount| row.merge("amount" => (amount * sign).to_s("F")) }
    end

    # Scales the parts to add up exactly to the target when they are off by no
    # more than the tolerance; the rounding remainder goes to the largest part.
    def fit_amounts(amounts, target, tolerance)
      total = amounts.sum
      return nil if (total - target).abs > tolerance

      scaled = amounts.map { |amount| (amount * target / total).round(2) }
      largest = scaled.index(scaled.max)
      scaled[largest] += target - scaled.sum
      scaled
    end

    # This family's category or nothing, so an invented name never becomes an id.
    def resolve_category(name)
      return nil if name.blank?

      family.categories.find_by(name: name) ||
        family.categories.find_by(Category.arel_table[:name].lower.eq(name.downcase))
    end

    def resolve_merchant(name)
      return nil if name.blank?

      merchants.find_by(name: name) || merchants.find_by(Merchant.arel_table[:name].lower.eq(name.downcase))
    end

    def resolve_tag_ids(names)
      return [] if names.blank?

      downcased = names.map(&:downcase)
      family.tags.select { |tag| downcased.include?(tag.name.downcase) }.map(&:id)
    end

    def merchants
      family.assignable_merchants_for(user)
    end

    # A subquery rather than a merge: accessible_by is DISTINCT, which
    # Postgres rejects next to ORDER BY on a column outside the select list.
    def accessible_transactions
      Transaction.joins(:entry).where(entries: { account_id: family.accounts.accessible_by(user).select(:id) })
    end

    def capture_failure(entry, suggestion, error)
      paperless = !self.class.llm_failure?(error)

      DebugLogEntry.capture(
        category: "ai_annotation",
        level: "warn",
        message: "Transaction annotation suggestion failed: #{error.class}: #{error.message}",
        source: self.class.name,
        family: family,
        account: entry.account,
        user: user,
        provider_key: paperless ? "paperless" : llm_provider_key,
        metadata: {
          entry_id: entry.id,
          suggestion_id: suggestion.id,
          suggestion_source: suggestion.source,
          receipt_link_id: suggestion.receipt_link_id,
          error_class: error.class.name,
          llm_provider: llm_provider_key,
          paperless_connection_id: suggestion.receipt_link&.paperless_connection_id,
          paperless_document_id: suggestion.receipt_link&.document_id
        }.compact
      )
    end
end
