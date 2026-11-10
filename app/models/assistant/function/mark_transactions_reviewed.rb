# frozen_string_literal: true

class Assistant::Function::MarkTransactionsReviewed < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

  MAX_IDS = 100

  class << self
    def name
      "mark_transactions_reviewed"
    end

    def description
      <<~INSTRUCTIONS
        Marks transactions of one review month as reviewed without changing
        them, like "Reviewed" on the monthly review card. Use it when the user
        confirms a transaction is fine as it is; use apply_transaction_annotation
        instead to apply a proposal (that marks it reviewed too).

        Only transactions of the given month that the user may edit are marked
        (transfers between the user's own accounts only with
        include_transfers); other ids are returned under not_found and left
        alone. Already reviewed
        transactions keep their original review. At most #{MAX_IDS} ids per call.

        Returns the ids marked now, the ids that were already reviewed, the ids
        not found, and the month's progress afterwards.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: %w[month transaction_ids],
      properties: {
        month: {
          type: "string",
          description: "The review month the transactions belong to, in #{MONTH_FORMAT}."
        },
        transaction_ids: {
          type: "array",
          items: { type: "string" },
          description: "Transaction ids from get_monthly_review or get_transactions."
        },
        include_transfers: INCLUDE_TRANSFERS_PROPERTY
      }
    )
  end

  def call(params = {})
    return error("invalid_month", "month is required (#{MONTH_FORMAT}).") if params["month"].blank?

    ids = Array(params["transaction_ids"]).map(&:to_s).compact_blank.uniq
    return error("invalid_arguments", "Pass at least one transaction id.") if ids.empty?
    return error("invalid_arguments", "Pass at most #{MAX_IDS} transaction ids per call.") if ids.size > MAX_IDS

    review, failure = find_review(params["month"], build: true)
    return failure if failure

    include_transfers = include_transfers?(params)
    entries = review.month_entries(review_entries, include_transfers: include_transfers).where(entryable_id: ids.select { |id| valid_uuid?(id) }).to_a
    already, unreviewed = entries.partition(&:reviewed?)
    Entry.where(id: unreviewed.map(&:id), reviewed_at: nil).update_all(reviewed_at: Time.current, reviewed_by_id: user.id) if unreviewed.any?

    found_ids = entries.map(&:entryable_id)
    {
      success: true,
      month: review.to_param,
      marked_ids: unreviewed.map(&:entryable_id),
      already_reviewed_ids: already.map(&:entryable_id),
      not_found_ids: ids - found_ids,
      progress: serialize_progress(review.progress(review_entries, include_transfers: include_transfers))
    }
  end
end
