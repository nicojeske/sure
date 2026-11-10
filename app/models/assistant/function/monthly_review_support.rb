# frozen_string_literal: true

# Shared plumbing for the monthly review tools. Tool calls never pass through
# the review controllers, so the lookups here use the same scopes they do:
# transactions come from the entries this user may annotate (owned accounts
# and full_control/read_write shares), a month must lie in the range budgets
# cover, and a transaction is reviewable only where the review cards would
# show it (no split parents, pending or excluded entries).
module Assistant::Function::MonthlyReviewSupport
  include Assistant::Function::MonthResolvable

  INCLUDE_TRANSFERS_PROPERTY = {
    type: "boolean",
    description: "Count transfers between the user's own accounts as part of the review, as the review page's \"include transfers\" toggle does. Default false."
  }.freeze

  private
    def include_transfers?(params)
      ActiveModel::Type::Boolean.new.cast(params["include_transfers"]) == true
    end

    def review_entries
      family.entries.joins(:account).merge(Account.annotatable_by(user))
    end

    # Everything the user can see, read-only shares included.
    def visible_entries
      family.entries.joins(:account).merge(Account.accessible_by(user))
    end

    # [review, error]. `build` returns an unsaved review for a month that was
    # never opened, so reading a month stores nothing.
    def find_review(raw_month, build: false)
      start_date = resolve_month_start(raw_month)
      unless Budget.budget_date_valid?(start_date, family: family)
        return [ nil, error("invalid_month", "#{raw_month.presence || "That month"} is outside the months Sure can review (about two years back, or your oldest transaction, up to two years ahead).") ]
      end

      [ build ? MonthlyReview.find_or_build(family, start_date) : MonthlyReview.for(family, start_date), nil ]
    rescue Assistant::Error => e
      [ nil, error("invalid_month", e.message) ]
    end

    # [entry, error] for a transaction id this user may annotate. A
    # transaction the user can only read is refused by name; any other id,
    # including one from another family, is simply not found.
    def find_review_entry(transaction_id)
      not_found = error("not_found", "No transaction with id '#{transaction_id}'. Use the ids from get_monthly_review or get_transactions.")
      return [ nil, not_found ] unless valid_uuid?(transaction_id)

      entry = review_entries.find_by(entryable_type: "Transaction", entryable_id: transaction_id)
      unless entry
        visible = visible_entries.exists?(entryable_type: "Transaction", entryable_id: transaction_id)
        return [ nil, visible ? read_only_error : not_found ]
      end

      unless MonthlyReview.reviewable_entries(review_entries, entry.date, include_transfers: true).exists?(entry.id)
        return [ nil, error("not_reviewable", "This transaction is not part of a monthly review (it is pending, excluded, or split into parts; review the parts instead).") ]
      end

      [ entry, nil ]
    end

    def already_reviewed_error
      error("already_reviewed", "This transaction is already reviewed. Undo its review on the review card first to change it.")
    end

    def read_only_error
      error("not_authorized", "This transaction is on an account shared with you read-only, so it can't be reviewed or changed.")
    end

    def serialize_progress(progress)
      { total: progress.total, reviewed: progress.reviewed, open: progress.remaining }
    end

    # Sparse: keys without a value are left out, and `reviewed` and
    # `receipt` appear only when true.
    def serialize_transaction(entry)
      transaction = entry.transaction
      row = {
        id: transaction.id,
        date: entry.date,
        name: entry.name,
        amount: entry.amount_money.abs.format,
        classification: entry.amount.negative? ? "income" : "expense",
        account: entry.account.name,
        merchant: transaction.merchant&.name,
        category: transaction.category&.name,
        tags: transaction.tags.map(&:name).presence,
        notes: entry.notes.presence
      }.compact
      row[:reviewed] = true if entry.reviewed?
      row[:receipt] = true if transaction.receipt_links.any? { |link| link.linked? || link.suggested? }
      row
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
