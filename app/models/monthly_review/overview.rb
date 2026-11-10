# The review overview: the latest budget months, newest first, each with its
# review (unsaved when the month was never opened) and progress. Progress
# for every month comes from one grouped query.
class MonthlyReview::Overview
  MONTHS = 12

  Month = Data.define(:review, :progress) do
    delegate :completed?, to: :review
  end

  def initialize(family, entries, include_transfers: false, today: Date.current, months: MONTHS)
    @family = family
    @entries = entries
    @include_transfers = include_transfers
    @today = today
    @count = months
  end

  def months
    @months ||= begin
      counts = MonthlyReview.progress_by_date(entries, periods.last.start_date..periods.first.end_date, include_transfers: include_transfers)
      reviews.map { |review| Month.new(review: review, progress: review.progress_from(counts)) }
    end
  end

  private
    attr_reader :family, :entries, :include_transfers, :today, :count

    def reviews
      existing = family.monthly_reviews.where(start_date: periods.map(&:start_date)).index_by(&:start_date)
      periods.map do |period|
        existing[period.start_date] || MonthlyReview.new(family_id: family.id, start_date: period.start_date, end_date: period.end_date)
      end
    end

    def periods
      @periods ||= begin
        current_start, = Budget.period_for(today, family: family)
        Array.new(count) do |index|
          start_date, end_date = Budget.period_for(current_start << index, family: family)
          Period.custom(start_date: start_date, end_date: end_date)
        end
      end
    end
end
