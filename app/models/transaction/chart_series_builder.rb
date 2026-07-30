class Transaction::ChartSeriesBuilder
  # Builds a cumulative net-flow Series and per-bucket income/expense totals from an
  # already-filtered Transaction::Search#transactions_scope, over `period`.
  #
  # `transactions_scope` may join `tags` (has_many through), which multiplies rows when
  # a transaction carries more than one selected tag. Aggregating over that relation
  # directly would double-count, so we first collapse it to one row per entry via
  # SELECT DISTINCT before summing.
  #
  # The cumulative line and the periodic bars intentionally use different bucket
  # sizes: a line reads fine with a year of daily points, but a bar chart with a
  # year of daily bars is unreadable (see Period#bar_interval). `granularity:` only
  # affects `periodic_totals`; pass an explicit day/week/month/year to override the
  # default derived from `period`, or leave it nil to auto-derive.
  GRANULARITIES = %w[day week month year].freeze

  def initialize(transactions_scope:, family:, period:, granularity: nil)
    @transactions_scope = transactions_scope
    @family = family
    @period = period
    @explicit_granularity = granularity
  end

  def granularity
    @granularity ||= @explicit_granularity.presence_in(GRANULARITIES) || period.bar_interval
  end

  def cumulative_series
    return empty_series unless any_matching_entries?

    running = 0
    values = bucketed_rows_for(cumulative_trunc_unit).map do |row|
      running += row["net"].to_d
      Series::Value.new(
        date: row["bucket"],
        date_formatted: I18n.l(row["bucket"], format: :long),
        value: Money.new(running, currency),
        trend: Trend.new(
          current: Money.new(running, currency),
          previous: Money.new(running - row["net"].to_d, currency),
          favorable_direction: "up"
        )
      )
    end

    Series.new(
      start_date: period.start_date,
      end_date: period.end_date,
      interval: period.interval,
      values: values,
      favorable_direction: "up"
    )
  end

  def periodic_totals
    return [] unless any_matching_entries?

    bucketed_rows_for(granularity).map do |row|
      {
        date: row["bucket"],
        label: bucket_label(row["bucket"], granularity),
        income: row["income"].to_f.round(2),
        expense: row["expense"].to_f.round(2),
        partial: row["bucket"] > Date.current
      }
    end
  end

  private
    attr_reader :transactions_scope, :family, :period

    def currency
      family.currency
    end

    def cumulative_trunc_unit
      period.interval.split(" ").last # "1 day" -> "day", "1 week" -> "week", "1 month" -> "month"
    end

    def bucket_label(date, unit)
      case unit
      when "year"
        date.strftime("%Y")
      when "month"
        I18n.l(date, format: :short_month_year)
      else
        I18n.l(date, format: :short)
      end
    end

    def any_matching_entries?
      @any_matching_entries = entries_in_window.exists? if @any_matching_entries.nil?
      @any_matching_entries
    end

    def entries_in_window
      scope = transactions_scope.where(entries: { date: period.start_date..period.end_date })

      # Mirror Transaction::Search#totals: retirement savings aren't daily income/expense.
      tax_advantaged_ids = family.tax_advantaged_account_ids
      scope = scope.where.not(accounts: { id: tax_advantaged_ids }) if tax_advantaged_ids.present?

      scope
    end

    def dedup_sql
      entries_in_window
        .select(
          "DISTINCT entries.id AS entry_id",
          "entries.date AS entry_date",
          "entries.amount AS entry_amount",
          "entries.currency AS entry_currency",
          "transactions.kind AS entry_kind"
        )
        .to_sql
    end

    def bucketed_rows_for(unit)
      @bucketed_rows_by_unit ||= {}
      @bucketed_rows_by_unit[unit] ||= ActiveRecord::Base.connection.select_all(sanitized_query_sql(unit)).to_a
    end

    def sanitized_query_sql(unit)
      ActiveRecord::Base.sanitize_sql_array([
        query_sql,
        {
          trunc_unit: unit,
          step: "1 #{unit}",
          start_date: period.start_date,
          end_date: period.end_date,
          transfer_kinds: Transaction::TRANSFER_KINDS,
          target_currency: currency
        }
      ])
    end

    def query_sql
      <<~SQL
        WITH buckets AS (
          SELECT generate_series(
            date_trunc(:trunc_unit, DATE :start_date),
            date_trunc(:trunc_unit, DATE :end_date),
            :step::interval
          )::date AS bucket
        ),
        dedup_entries AS (
          #{dedup_sql}
        ),
        agg AS (
          SELECT
            date_trunc(:trunc_unit, e.entry_date)::date AS bucket,
            COALESCE(SUM(CASE WHEN e.entry_amount < 0 AND e.entry_kind NOT IN (:transfer_kinds)
                         THEN ABS(e.entry_amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN e.entry_amount >= 0 AND e.entry_kind NOT IN (:transfer_kinds)
                         THEN ABS(e.entry_amount * COALESCE(er.rate, 1)) ELSE 0 END), 0) AS expense,
            COALESCE(SUM(-e.entry_amount * COALESCE(er.rate, 1)), 0) AS net
          FROM dedup_entries e
          LEFT JOIN exchange_rates er ON (
            er.date = e.entry_date AND
            er.from_currency = e.entry_currency AND
            er.to_currency = :target_currency
          )
          GROUP BY 1
        )
        SELECT
          b.bucket,
          COALESCE(agg.income, 0) AS income,
          COALESCE(agg.expense, 0) AS expense,
          COALESCE(agg.net, 0) AS net
        FROM buckets b
        LEFT JOIN agg ON agg.bucket = b.bucket
        ORDER BY b.bucket
      SQL
    end

    def empty_series
      Series.new(
        start_date: period.start_date,
        end_date: period.end_date,
        interval: period.interval,
        values: [],
        favorable_direction: "up"
      )
    end
end
