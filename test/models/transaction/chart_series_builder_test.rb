require "test_helper"

class Transaction::ChartSeriesBuilderTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @checking_account = accounts(:depository)
    @admin = users(:family_admin)

    # Clean up existing entries/transactions from fixtures to ensure test isolation
    @family.accounts.each { |account| account.entries.delete_all }

    @period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)
  end

  test "cumulative series descends for expenses and ends at the negated total" do
    create_transaction(account: @checking_account, amount: 50, date: 5.days.ago.to_date, kind: "standard")
    create_transaction(account: @checking_account, amount: 30, date: 2.days.ago.to_date, kind: "standard")

    series = builder_for(Transaction::Search.new(@family)).cumulative_series

    assert series.any?
    assert_equal Money.new(-80, "USD"), series.values.last.value
  end

  test "marks only buckets with real activity, not every zero-filled bucket" do
    active_date = 8.days.ago.to_date
    create_transaction(account: @checking_account, amount: 40, date: active_date, kind: "standard")

    series = builder_for(Transaction::Search.new(@family)).cumulative_series

    active = series.values.select(&:has_activity)
    assert_equal [ active_date ], active.map(&:date)
  end

  test "multi-tag filter does not double count" do
    tag_a = tags(:one)
    tag_b = tags(:two)

    entry = create_transaction(account: @checking_account, amount: 100, date: 3.days.ago.to_date, kind: "standard")
    entry.transaction.tags = [ tag_a, tag_b ]

    search = Transaction::Search.new(@family, filters: { tags: [ tag_a.name, tag_b.name ] })
    # Sanity check: the underlying scope really is multiplied by the tag join.
    assert_equal 2, search.transactions_scope.count

    series = builder_for(search).cumulative_series

    assert_equal Money.new(-100, "USD"), series.values.last.value
  end

  test "zero-filled buckets keep gaps flat rather than interpolating" do
    txn_date = 8.days.ago.to_date
    create_transaction(account: @checking_account, amount: 40, date: txn_date, kind: "standard")

    series = builder_for(Transaction::Search.new(@family)).cumulative_series

    assert_equal (@period.end_date - @period.start_date).to_i + 1, series.values.size

    series.values.select { |v| v.date > txn_date }.each do |v|
      assert_equal Money.new(-40, "USD"), v.value, "expected a flat line after the only transaction"
    end
  end

  test "empty result set returns an empty series instead of raising" do
    series = builder_for(Transaction::Search.new(@family, filters: { merchants: [ "Nonexistent Merchant" ] })).cumulative_series

    assert_not series.any?
  end

  test "excludes tax-advantaged accounts, matching Transaction::Search#totals" do
    hsa_account = @family.accounts.create!(
      owner: @admin,
      name: "Test HSA",
      balance: 0,
      currency: "USD",
      accountable: Depository.new(subtype: "hsa")
    )

    create_transaction(account: @checking_account, amount: 50, date: 3.days.ago.to_date, kind: "standard")
    create_transaction(account: hsa_account, amount: 200, date: 3.days.ago.to_date, kind: "standard")

    search = Transaction::Search.new(@family)
    series = builder_for(search).cumulative_series

    expected = search.totals.income_money - search.totals.expense_money
    assert_equal expected, series.values.last.value
    assert_equal Money.new(-50, "USD"), series.values.last.value
  end

  test "periodic granularity defaults from the period's span when not explicit" do
    short_period = Period.custom(start_date: 10.days.ago.to_date, end_date: Date.current)
    long_period = Period.custom(start_date: 6.years.ago.to_date, end_date: Date.current)

    assert_equal "day", builder_for(Transaction::Search.new(@family), period: short_period).granularity
    assert_equal "year", builder_for(Transaction::Search.new(@family), period: long_period).granularity
  end

  test "an explicit granularity overrides the period-derived default" do
    long_period = Period.custom(start_date: 6.years.ago.to_date, end_date: Date.current)

    builder = builder_for(Transaction::Search.new(@family), period: long_period, granularity: "week")

    assert_equal "week", builder.granularity
  end

  test "an invalid explicit granularity falls back to the default" do
    builder = builder_for(Transaction::Search.new(@family), granularity: "fortnight")

    assert_equal "day", builder.granularity
  end

  test "periodic_totals buckets by month and labels with month/year when granularity is month" do
    period = Period.custom(start_date: 4.months.ago.to_date.beginning_of_month, end_date: Date.current)
    create_transaction(account: @checking_account, amount: 50, date: 2.months.ago.to_date, kind: "standard")
    create_transaction(account: @checking_account, amount: 30, date: 2.months.ago.to_date - 1.day, kind: "standard")

    bars = builder_for(Transaction::Search.new(@family), period: period, granularity: "month").periodic_totals

    assert_equal 5, bars.size # 4 full months back through the current one, inclusive
    assert_match(/\A[A-Z][a-z]{2} \d{4}\z/, bars.first[:label]) # e.g. "Mar 2026"

    target_month_bucket = bars.find { |b| b[:date] == 2.months.ago.to_date.beginning_of_month }
    assert_equal 80.0, target_month_bucket[:expense]
  end

  test "periodic_totals labels a year bucket with just the year" do
    period = Period.custom(start_date: 6.years.ago.to_date, end_date: Date.current)
    create_transaction(account: @checking_account, amount: 100, date: 3.years.ago.to_date, kind: "standard")

    bars = builder_for(Transaction::Search.new(@family), period: period, granularity: "year").periodic_totals

    target_year_bucket = bars.find { |b| b[:date] == 3.years.ago.to_date.beginning_of_year }
    assert_equal 3.years.ago.to_date.year.to_s, target_year_bucket[:label]
    assert_equal 100.0, target_year_bucket[:expense]
  end

  private
    def builder_for(search, period: @period, granularity: nil)
      Transaction::ChartSeriesBuilder.new(
        transactions_scope: search.transactions_scope,
        family: @family,
        period: period,
        granularity: granularity
      )
    end
end
