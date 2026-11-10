# What a month's review page shows: income and expense from the income
# statement, and how far the review got.
#
# Skips are not stored, so they are derived from queue order: an unreviewed
# entry before the last reviewed one was passed over (skipped), one after it
# was not reached yet (open). Once the month is completed every unreviewed
# entry counts as skipped.
class MonthlyReview::Summary
  attr_reader :review, :list

  def initialize(review, entries, user:, include_transfers: false)
    @review = review
    @user = user
    @list = review.card_list(entries, include_transfers: include_transfers)
  end

  def total = list.size
  def reviewed_count = list.reviewed_ids.size
  def skipped_count = unreviewed_entries.count { |entry| status(entry) == "skipped" }
  def open_count = unreviewed_entries.size - skipped_count

  def progress
    MonthlyReview::Progress.new(total: total, reviewed: reviewed_count)
  end

  def unreviewed_entries
    @unreviewed_entries ||= list.reject(&:reviewed?)
  end

  # The list status of an entry: reviewed, skipped or pending (open).
  def status(entry)
    return "reviewed" if entry.reviewed?
    return "skipped" if review.completed?

    last_reviewed_position && list.position(entry) < last_reviewed_position ? "skipped" : "pending"
  end

  def income
    Money.new(income_statement.income_totals(period: review.period).total, review.family.currency)
  end

  def expense
    Money.new(income_statement.expense_totals(period: review.period).total, review.family.currency)
  end

  def net
    income - expense
  end

  private
    attr_reader :user

    def income_statement
      @income_statement ||= review.family.income_statement(user: user)
    end

    def last_reviewed_position
      return @last_reviewed_position if defined?(@last_reviewed_position)

      last = list.entries.reverse.find(&:reviewed?)
      @last_reviewed_position = last && list.position(last)
    end
end
