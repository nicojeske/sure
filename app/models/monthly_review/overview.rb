# The review overview: one year's budget months, newest first, each with its
# review (unsaved when the month was never opened) and progress. A month
# belongs to the year of its label (its start date), so with a custom month
# start the year still lists the months labelled January to December.
# Months after the current one, and before the one holding the family's
# oldest entry, are left out. Progress for every month comes from one
# grouped query.
class MonthlyReview::Overview
  Month = Data.define(:review, :progress) do
    delegate :completed?, to: :review

    def status = review.status(progress)
  end

  # `year` is clamped to the years from the oldest entry to the current one;
  # nil means the current year.
  def initialize(family, entries, year: nil, include_transfers: false, today: Date.current)
    @family = family
    @entries = entries
    @requested_year = year
    @include_transfers = include_transfers
    @today = today
  end

  def year
    @year ||= (requested_year || current_year).clamp(oldest_year, current_year)
  end

  def previous_year
    year - 1 if year > oldest_year
  end

  def next_year
    year + 1 if year < current_year
  end

  def months
    @months ||= begin
      counts = MonthlyReview.progress_by_date(entries, periods.last.start_date..periods.first.end_date, include_transfers: include_transfers)
      reviews.map { |review| Month.new(review: review, progress: review.progress_from(counts)) }
    end
  end

  private
    attr_reader :family, :entries, :requested_year, :include_transfers, :today

    def reviews
      existing = family.monthly_reviews.where(start_date: periods.map(&:start_date)).index_by(&:start_date)
      periods.map do |period|
        existing[period.start_date] || MonthlyReview.new(family_id: family.id, start_date: period.start_date, end_date: period.end_date)
      end
    end

    def periods
      @periods ||= 12.downto(1).filter_map do |month|
        start_date, end_date = Budget.period_for(Date.new(year, month, family.month_start_day), family: family)
        Period.custom(start_date: start_date, end_date: end_date) if start_date.between?(oldest_start, current_start)
      end
    end

    def current_start
      @current_start ||= Budget.period_for(today, family: family).first
    end

    def current_year
      current_start.year
    end

    def oldest_year
      oldest_start.year
    end

    # The month holding the family's oldest entry, never after the current one.
    def oldest_start
      @oldest_start ||= [ Budget.period_for(family.oldest_entry_date, family: family).first, current_start ].min
    end
end
