# What one monthly-review card shows for an entry: which proposal is current,
# the state the card is in, and the five field rows (always all five, in
# TransactionAnnotationSuggestion::FIELDS order, so rows never move between
# cards).
#
# The proposal is, in order: the one the URL names, the latest hint, the one
# for the receipt the card reads (linked or clear-cut suggested), the latest
# one for a close receipt candidate, and the learned category when there is
# no receipt at all. Building a card never calls the LLM; the learned
# proposal is stored because applying needs a record.
class MonthlyReview::Card
  STATES = %i[reviewed loading failed unread receipt_choice proposal empty].freeze
  OPEN_STATUSES = %w[pending ready failed reverted].freeze

  # status: :change (proposed and selectable), :locked (proposed but this user
  # may not change it), :applied (changed when the card was accepted) or
  # :unchanged.
  Field = Data.define(:key, :number, :current, :proposed, :status, :checked) do
    def change? = status == :change
  end
  SplitPart = Data.define(:name, :amount, :category)
  NewMerchant = Data.define(:name)

  attr_reader :review, :entry, :user, :suggestion

  def initialize(review, entry, user:, suggestion_id: nil)
    @review = review
    @entry = entry
    @user = user
    @suggestion_id = suggestion_id
    resolve
  end

  def transaction
    entry.transaction
  end

  def state
    @state
  end

  def reviewed? = state == :reviewed

  # Background prefetch began recently, so an unread receipt is probably next
  # in its queue.
  def queued?
    state == :unread && review.prefetched_at.present? && review.prefetched_at > MonthlyReview::PREFETCH_INTERVAL.ago
  end

  def original_name
    transaction.extra&.dig("original_name").presence
  end

  # The receipt this card reads or was built from.
  def receipt_link
    return @receipt_link if defined?(@receipt_link)

    @receipt_link = suggestion&.receipt_link ||
      (reviewed? ? transaction.receipt_links.find(&:linked?) : receipt_choice.link)
  end

  def receipt_candidates
    state == :receipt_choice ? receipt_choice.candidates : []
  end

  def receipt_mismatch?
    proposal? && suggestion.payload["receipt_amount_mismatch"] == true
  end

  def proposal?
    state == :proposal
  end

  def learned?
    suggestion&.learned?
  end

  def confidence
    suggestion&.payload&.dig("confidence")
  end

  def rationale
    suggestion&.payload&.dig("rationale").presence
  end

  def hint_text
    suggestion&.hint_text if suggestion&.hint?
  end

  def fields
    @fields ||= TransactionAnnotationSuggestion::FIELDS.each_with_index.map do |key, index|
      status = field_status(key)
      Field.new(
        key: key,
        number: index + 1,
        current: current_value(key),
        proposed: status.in?(%i[change locked]) ? proposed_value(key) : nil,
        status: status,
        checked: status == :change && selection[key] == true
      )
    end
  end

  def changes?
    fields.any?(&:change?) || split_parts.any?
  end

  def split_parts
    return [] unless proposal? && suggestion.split

    @split_parts ||= begin
      categories = Category.where(id: suggestion.split.filter_map { |part| part["category_id"] }).index_by(&:id)
      suggestion.split.map do |part|
        SplitPart.new(name: part["name"], amount: Money.new(part["amount"].to_d, entry.currency), category: categories[part["category_id"]])
      end
    end
  end

  def split_selectable?
    selection.key?("split")
  end

  def split_checked?
    selection["split"] == true
  end

  # Fields this user may change by hand (edit mode).
  def editable_fields
    @editable_fields ||= TransactionAnnotationSuggestion::Applier.permitted_fields(entry, user)
  end

  # Number of fields (and the split) the accepted proposal changed.
  def applied_change_count
    return 0 unless reviewed? && suggestion

    applied = suggestion.applied_fields || {}
    Array(applied["fields"]).size + (applied["split"] ? 1 : 0)
  end

  private
    def resolve
      if entry.reviewed?
        @suggestion = TransactionAnnotationSuggestion.applied_in_review_of(entry)
        @state = :reviewed
        return
      end

      @suggestion = explicit_suggestion || latest_hint_suggestion || receipt_suggestion || candidate_suggestion
      @suggestion ||= learned_suggestion if receipt_choice.link.nil? && receipt_choice.candidates.empty?
      @state = state_for(@suggestion)
    end

    def state_for(suggestion)
      if suggestion.nil?
        return :unread if receipt_choice.link
        return :receipt_choice if receipt_choice.candidates.any?
        return :empty
      end

      return :loading if suggestion.in_flight?
      return :failed if suggestion.pending? || suggestion.failed?
      return :proposal if suggestion.applicable?

      :empty
    end

    def receipt_choice
      @receipt_choice ||= Transaction::AnnotationSuggester.receipt_choice(transaction)
    end

    def suggestions
      @suggestions ||= entry.annotation_suggestions.includes(:receipt_link).order(updated_at: :desc).to_a
    end

    def explicit_suggestion
      suggestions.find { |suggestion| suggestion.id == @suggestion_id } if @suggestion_id.present?
    end

    def latest_hint_suggestion
      suggestions.find { |suggestion| suggestion.hint? && suggestion.status.in?(OPEN_STATUSES) }
    end

    def receipt_suggestion
      return nil unless (link = receipt_choice.link)

      input_hash = Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: link)
      suggestions.find { |suggestion| suggestion.input_hash == input_hash && suggestion.status.in?(OPEN_STATUSES) }
    end

    def candidate_suggestion
      candidate_ids = receipt_choice.candidates.map(&:id)
      suggestions.find { |suggestion| suggestion.receipt? && suggestion.receipt_link_id.in?(candidate_ids) && suggestion.status.in?(OPEN_STATUSES) }
    end

    def learned_suggestion
      suggestion = Transaction::AnnotationSuggester.new(review.family, user: user).learned_suggestion(entry)
      suggestion if suggestion&.applicable?
    end

    def selection
      @selection ||= proposal? ? suggestion.default_selection(user) : {}
    end

    def proposed_fields
      @proposed_fields ||= proposal? ? suggestion.proposed_fields : []
    end

    def field_status(key)
      if reviewed?
        Array(suggestion&.applied_fields&.dig("fields")).include?(key) ? :applied : :unchanged
      elsif proposed_fields.include?(key)
        selection.key?(key) ? :change : :locked
      else
        :unchanged
      end
    end

    def current_value(key)
      case key
      when "name" then entry.name
      when "merchant" then transaction.merchant
      when "category" then transaction.category
      when "tags" then transaction.tags.to_a
      when "notes" then entry.notes.presence
      end
    end

    def proposed_value(key)
      payload = suggestion.payload

      case key
      when "name", "notes" then payload[key]
      when "merchant"
        payload["new_merchant_name"].present? ? NewMerchant.new(name: payload["new_merchant_name"]) : Merchant.find_by(id: payload["merchant_id"])
      when "category" then review.family.categories.find_by(id: payload["category_id"])
      when "tags" then review.family.tags.where(id: payload["tag_ids"]).alphabetically.to_a
      end
    end
end
