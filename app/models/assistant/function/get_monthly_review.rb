# frozen_string_literal: true

class Assistant::Function::GetMonthlyReview < Assistant::Function
  include Assistant::Function::MonthlyReviewSupport

  MAX_OPEN_TRANSACTIONS = 50

  class << self
    def name
      "get_monthly_review"
    end

    def description
      <<~INSTRUCTIONS
        Reads one month of the monthly review, where the user goes through the
        month's transactions one by one, marks each reviewed, and finally writes
        a note and completes the month. Changes nothing.

        Returns the month's review status (not_started, in_progress, ready = all
        reviewed but not completed, completed, empty), progress counts (total,
        reviewed, open), income, expense and net for the month, the month's note,
        and the open (unreviewed) transactions in review order, at most
        #{MAX_OPEN_TRANSACTIONS} per call. `receipt: true` marks a transaction
        with a Paperless receipt to read.

        To walk through the open transactions: call suggest_transaction_annotation
        for one, show the proposal, then apply_transaction_annotation (applies
        and marks it reviewed) or mark_transactions_reviewed (keeps it as is).
        Call this again for the next batch. Finish with update_monthly_review.

        Transfers between the user's own accounts are left out unless
        include_transfers is true. Only transactions the user may edit count.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      properties: {
        month: {
          type: "string",
          description: "Month in #{MONTH_FORMAT}. Defaults to the current month. Families with a custom month start use the budget month that starts in it."
        },
        include_transfers: INCLUDE_TRANSFERS_PROPERTY
      }
    )
  end

  def call(params = {})
    review, failure = find_review(params["month"], build: true)
    return failure if failure

    summary = MonthlyReview::Summary.new(review, review_entries, user: user, include_transfers: include_transfers?(params))
    open_entries = summary.open_entries.first(MAX_OPEN_TRANSACTIONS)
    ActiveRecord::Associations::Preloader.new(records: open_entries.map(&:transaction), associations: %i[category tags]).call

    result = {
      month: review.to_param,
      start_date: review.start_date,
      end_date: review.end_date,
      status: review.status(summary.progress).to_s,
      completed_at: review.completed_at,
      notes: review.notes,
      progress: serialize_progress(summary.progress),
      income: summary.income.format,
      expense: summary.expense.format,
      net: summary.net.format,
      open_transactions: open_entries.map { |entry| serialize_transaction(entry) }
    }
    result[:open_transactions_truncated] = true if summary.open_count > open_entries.size
    result
  end
end
