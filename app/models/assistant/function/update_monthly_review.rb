# frozen_string_literal: true

class Assistant::Function::UpdateMonthlyReview < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

  COMPLETIONS = %w[complete reopen].freeze

  class << self
    def name
      "update_monthly_review"
    end

    def description
      <<~INSTRUCTIONS
        Saves the note of a review month and completes or reopens the month,
        like the month's summary page. Completing is allowed while transactions
        are still open; they stay unreviewed.

        `notes` replaces the month's note (null or "" clears it); omit it to
        keep the note. `completion` is "complete" or "reopen"; omit it to leave
        the month as it is.

        Guests and members who can only read shared accounts can't change a
        review. Returns the month's note, status and progress.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "month" ],
      properties: {
        month: {
          type: "string",
          description: "The review month, in #{MONTH_FORMAT}."
        },
        notes: {
          type: [ "string", "null" ],
          description: "The month's note. Replaces the existing note; null or empty clears it. Omit to keep it."
        },
        completion: {
          type: "string",
          enum: COMPLETIONS,
          description: "complete to sign the month off, reopen to undo that. Omit to leave it."
        },
        include_transfers: INCLUDE_TRANSFERS_PROPERTY
      }
    )
  end

  def call(params = {})
    return error("not_authorized", "You can't change monthly reviews: guests and members with only read-only shares can only read them.") unless MonthlyReview.editable_by?(user)
    return error("invalid_month", "month is required (#{MONTH_FORMAT}).") if params["month"].blank?
    return error("no_changes", "Provide notes, completion or both.") unless params.key?("notes") || params.key?("completion")

    completion = params["completion"]
    if params.key?("completion") && !COMPLETIONS.include?(completion)
      return error("invalid_arguments", "completion must be one of: #{COMPLETIONS.join(", ")}.")
    end

    review, failure = find_review(params["month"])
    return failure if failure

    MonthlyReview.transaction do
      review.update!(notes: params["notes"].presence) if params.key?("notes")
      case completion
      when "complete" then review.complete!
      when "reopen" then review.reopen!
      end
    end

    progress = review.progress(review_entries, include_transfers: include_transfers?(params))
    {
      success: true,
      month: review.to_param,
      notes: review.notes,
      status: review.status(progress).to_s,
      completed_at: review.completed_at,
      progress: serialize_progress(progress)
    }
  rescue ActiveRecord::RecordInvalid => e
    error("validation_failed", e.record.errors.full_messages.join("; "))
  end
end
