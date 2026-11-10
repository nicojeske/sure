# What one monthly-review card shows for an entry: which proposal is current,
# the state the card is in, and the five field rows (always all five, in
# TransactionAnnotationSuggestion::FIELDS order, so rows never move between
# cards).
#
# The proposal is, in order: the one the URL names, the latest hint, the one
# for the receipt the card reads (linked or clear-cut suggested), the latest
# one for a close receipt candidate, and the learned category when there is
# no receipt at all. Building a card never calls the LLM; the learned
# proposal is stored because applying needs a record, and
# read_receipt_later! starts the background read of an unread receipt.
class MonthlyReview::Card
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

  # Starts reading an unread receipt in the background; the card then waits
  # for it (state :loading).
  def read_receipt_later!
    return unless state == :unread && review.read_receipt_later(entry, user)

    @suggestions = nil
    resolve
  end

  # The card has a receipt to read, but no LLM provider or Paperless
  # connection to read it with.
  def reading_unavailable?
    state == :empty && suggestion.nil? && receipt_choice.link.present? && !review.suggestions_available?
  end

  def edited?
    suggestion&.edited? == true
  end

  # What edit mode starts with: the proposed value of a field the proposal
  # changes, else the current one. A merchant that does not exist yet can't be
  # picked, so it starts with the current merchant.
  def edit_value(key)
    field = fields.find { |candidate| candidate.key == key }
    proposed = field.proposed if field.change?
    proposed.nil? || proposed.is_a?(NewMerchant) ? field.current : proposed
  end

  delegate :original_name, to: :transaction

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
      categories = review.family.categories.where(id: suggestion.split.filter_map { |part| part["category_id"] }).index_by(&:id)
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
        return :unread if receipt_choice.link && review.suggestions_available?
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
      suggestions.find { |suggestion| suggestion.hint? && open_proposal?(suggestion) }
    end

    def receipt_suggestion
      return nil unless (link = receipt_choice.link)

      input_hash = Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: link)
      suggestions.find { |suggestion| suggestion.input_hash == input_hash && open_proposal?(suggestion) }
    end

    def candidate_suggestion
      candidate_ids = receipt_choice.candidates.map(&:id)
      suggestions.find { |suggestion| suggestion.receipt? && suggestion.receipt_link_id.in?(candidate_ids) && open_proposal?(suggestion) }
    end

    # A proposal the card may still offer. Edits saved from edit mode are
    # offered only while the URL names them.
    def open_proposal?(suggestion)
      suggestion.status.in?(OPEN_STATUSES) && !suggestion.edited?
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
        payload["new_merchant_name"].present? ? NewMerchant.new(name: payload["new_merchant_name"]) : review.family.assignable_merchants_for(user).find_by(id: payload["merchant_id"])
      when "category" then review.family.categories.find_by(id: payload["category_id"])
      when "tags" then review.family.tags.where(id: payload["tag_ids"]).alphabetically.to_a
      end
    end
end
