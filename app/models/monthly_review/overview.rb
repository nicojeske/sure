# The review overview: the latest budget months, newest first, each with its
# review (unsaved when the month was never opened) and progress. Progress
# for every month comes from one grouped query.
class MonthlyReview::Overview
  MONTHS = 12

  Month = Data.define(:review, :progress) do
    def completed? = review.completed?
    def started? = progress.reviewed.positive?
  end

  attr_reader :family

  def initialize(family, entries, include_transfers: false, today: Date.current, months: MONTHS)
    @family = family
    @entries = entries
    @include_transfers = include_transfers
    @today = today
    @count = months
  end

  def months
    @months ||= begin
      counts = daily_counts
      reviews.map do |review|
        days = counts.select { |date, _| review.start_date <= date && date <= review.end_date }.values
        Month.new(review: review, progress: MonthlyReview::Progress.new(total: days.sum(&:first), reviewed: days.sum(&:last)))
      end
    end
  end

  private
    attr_reader :entries, :include_transfers, :today, :count

    def reviews
      existing = family.monthly_reviews.where(start_date: periods.map(&:first)).index_by(&:start_date)
      periods.map do |start_date, end_date|
        existing[start_date] || MonthlyReview.new(family_id: family.id, start_date: start_date, end_date: end_date)
      end
    end

    def periods
      @periods ||= begin
        current_start, = Budget.period_for(today, family: family)
        Array.new(count) { |index| Budget.period_for(current_start << index, family: family) }
      end
    end

    # { date => [total, reviewed] } over all listed months.
    def daily_counts
      dates = periods.last.first..periods.first.last
      MonthlyReview.reviewable_entries(entries, dates, include_transfers: include_transfers)
        .group("entries.date")
        .pluck("entries.date", Arel.sql("COUNT(*)"), Arel.sql("COUNT(entries.reviewed_at)"))
        .to_h { |date, total, reviewed| [ date, [ total, reviewed ] ] }
    end
end
