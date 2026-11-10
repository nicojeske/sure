# frozen_string_literal: true

class Assistant::Function::ApplyTransactionAnnotation < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

  FIELDS = TransactionAnnotationSuggestion::FIELDS

  class << self
    def name
      "apply_transaction_annotation"
    end

    def description
      <<~INSTRUCTIONS
        Applies a proposal from suggest_transaction_annotation to its
        transaction and marks the transaction reviewed, like accepting the
        monthly review card. The change is saved as the user's own edit and can
        be undone on the review card.

        `fields` picks which proposed changes to apply (any of
        #{FIELDS.join(", ")}); omit it to apply the ones the proposal selected by
        default. Fields the proposal doesn't change are ignored. `split: true`
        also splits the transaction into the proposed parts; omit it to follow
        the proposal's default.

        Only the user's own accounts and accounts shared with edit rights can be
        changed; renaming and splitting need full control of the account.

        Returns the transaction as it is now, the fields applied and whether
        it was split.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "suggestion_id" ],
      properties: {
        suggestion_id: {
          type: "string",
          description: "suggestion_id returned by suggest_transaction_annotation."
        },
        fields: {
          type: "array",
          items: { type: "string", enum: FIELDS },
          description: "Proposed changes to apply. Omit to apply the default selection; an empty array applies none and only marks the transaction reviewed."
        },
        split: {
          type: "boolean",
          description: "Split the transaction into the proposed parts. Omit to follow the proposal's default."
        }
      }
    )
  end

  def call(params = {})
    suggestion = find_suggestion(params["suggestion_id"])
    return error("not_found", "No proposal with id '#{params["suggestion_id"]}'. Call suggest_transaction_annotation first.") unless suggestion

    entry = suggestion.entry
    _, failure = find_review_entry(entry.entryable_id)
    return failure if failure
    return error("already_reviewed", "This transaction is already reviewed. Undo its review on the review card first to change it.") if entry.reviewed?
    return error("not_applicable", "This proposal is #{suggestion.status} and can't be applied. Call suggest_transaction_annotation again.") unless suggestion.applicable?

    selection = suggestion.default_selection(user)
    fields = selection.keys - [ "split" ]
    permitted = TransactionAnnotationSuggestion::Applier.permitted_fields(entry, user)

    if params.key?("fields")
      requested = Array(params["fields"]).map(&:to_s).uniq
      unknown = requested - FIELDS
      return error("invalid_fields", "Unknown fields: #{unknown.join(", ")}. Use any of #{FIELDS.join(", ")}.") if unknown.any?

      forbidden = requested & (suggestion.proposed_fields - permitted)
      return error("field_not_allowed", "You may not change #{forbidden.join(", ")} on this transaction.") if forbidden.any?

      fields = requested & fields
    else
      fields = fields.select { |field| selection[field] }
    end

    split = params.key?("split") ? ActiveModel::Type::Boolean.new.cast(params["split"]) == true : selection["split"] == true
    if split && !selection.key?("split")
      return error("split_not_allowed", suggestion.split ? "Splitting needs full control of the account." : "This proposal has no split.")
    end

    suggestion.apply!(user: user, fields: fields, split: split)
    applied = suggestion.applied_fields

    {
      success: true,
      transaction: serialize_transaction(entry.reload),
      applied_fields: applied["fields"],
      split: applied["split"] == true,
      reviewed: true
    }
  rescue TransactionAnnotationSuggestion::Applier::Error => e
    error("apply_failed", e.message)
  end

  private
    # Looked up among the transactions the user can see, so a read-only
    # share is refused by name below; another family's id is not found.
    def find_suggestion(id)
      return nil unless valid_uuid?(id)

      TransactionAnnotationSuggestion.not_edited.where(entry_id: visible_entries.select(:id)).find_by(id: id)
    end

    def serialize_transaction(entry)
      transaction = entry.transaction
      row = {
        id: transaction.id,
        name: entry.name,
        merchant: transaction.merchant&.name,
        category: transaction.category&.name,
        tags: transaction.tags.map(&:name),
        notes: entry.notes.presence
      }.compact
      row[:parts] = entry.child_entries.map { |part| { id: part.entryable_id, name: part.name, amount: part.amount_money.abs.format } } if entry.split_parent?
      row
    end
end
