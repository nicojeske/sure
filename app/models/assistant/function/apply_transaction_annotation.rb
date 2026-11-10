# frozen_string_literal: true

class Assistant::Function::ApplyTransactionAnnotation < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

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
        #{TransactionAnnotationSuggestion::FIELDS.join(", ")}); omit it or pass
        null to apply the ones the proposal selects by default. Fields the
        proposal doesn't change are ignored. `split: true` also splits the
        transaction into the proposed parts; omit it to follow the proposal's
        default. A call that would apply nothing at all is refused
        (no_fields_selected); to keep a transaction as it is, use
        mark_transactions_reviewed.

        Only the user's own accounts and accounts shared with edit rights can be
        changed; renaming and splitting need full control of the account.

        Returns the transaction as it is now (with its `parts` after a split),
        the fields applied and whether it was split.
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
          type: [ "array", "null" ],
          items: { type: "string", enum: TransactionAnnotationSuggestion::FIELDS },
          description: "Proposed changes to apply. Omit or null to apply the default selection. An empty array applies no field and is only allowed together with split: true."
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
    return already_reviewed_error if entry.reviewed?
    return error("not_applicable", "This proposal is #{suggestion.status} and can't be applied. Call suggest_transaction_annotation again.") unless suggestion.applicable?

    selection = suggestion.default_selection(user)
    fields = selection.keys - [ "split" ]
    permitted = TransactionAnnotationSuggestion::Applier.permitted_fields(entry, user)

    if params["fields"].nil?
      fields = fields.select { |field| selection[field] }
    else
      requested = Array(params["fields"]).map(&:to_s).uniq
      unknown = requested - TransactionAnnotationSuggestion::FIELDS
      return error("invalid_fields", "Unknown fields: #{unknown.join(", ")}. Use any of #{TransactionAnnotationSuggestion::FIELDS.join(", ")}.") if unknown.any?

      forbidden = requested & (suggestion.proposed_fields - permitted)
      return error("field_not_allowed", "You may not change #{forbidden.join(", ")} on this transaction.") if forbidden.any?

      fields = requested & fields
    end

    split = params.key?("split") ? ActiveModel::Type::Boolean.new.cast(params["split"]) == true : selection["split"] == true
    if split && !selection.key?("split")
      return error("split_not_allowed", suggestion.split ? "Splitting needs full control of the account." : "This proposal has no split.")
    end
    if fields.empty? && !split
      return error("no_fields_selected", "Nothing to apply: none of the chosen fields is a change this proposal makes. Pick fields from its changes, or use mark_transactions_reviewed to keep the transaction as it is.")
    end

    suggestion.apply!(user: user, fields: fields, split: split)
    applied = suggestion.applied_fields

    transaction = serialize_transaction(entry.reload)
    transaction[:parts] = entry.child_entries.order(:created_at, :id).map { |part| serialize_transaction(part) } if entry.split_parent?
    {
      success: true,
      transaction: transaction,
      applied_fields: applied["fields"],
      split: applied["split"] == true
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
end
