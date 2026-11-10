# What a month's review page shows: income and expense from the income
# statement, and how many transactions are reviewed or still open. Skips
# aren't stored, so a transaction passed over on the cards is simply open.
class MonthlyReview::Summary
  attr_reader :review, :list

  def initialize(review, entries, user:, include_transfers: false)
    @review = review
    @user = user
    @list = review.card_list(entries, include_transfers: include_transfers)
  end

  def total = list.size
  def reviewed_count = list.reviewed_ids.size
  def open_count = open_entries.size

  def progress
    MonthlyReview::Progress.new(total: total, reviewed: reviewed_count)
  end

  def open_entries
    @open_entries ||= list.reject(&:reviewed?)
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
end
