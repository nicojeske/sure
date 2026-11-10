require "test_helper"

class MonthlyReview::OverviewTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }
    @today = Date.new(2026, 11, 10)
    # The family's oldest entry, so the years 2024 to 2026 can be reviewed.
    create_transaction(account: @account, date: Date.new(2024, 3, 9), name: "Oldest")
  end

  test "opens on the current year, newest first, hiding future months, without creating reviews" do
    assert_no_difference "MonthlyReview.count" do
      months = overview.months

      assert_equal 2026, overview.year
      assert_equal 11, months.size
      assert_equal Date.new(2026, 11, 1), months.first.review.start_date
      assert_equal Date.new(2026, 1, 1), months.last.review.start_date
      assert_equal Date.new(2026, 1, 31), months.last.review.end_date
      assert_equal "nov-2026", months.first.review.to_param
    end
  end

  test "lists every month of an earlier year" do
    review = overview(year: 2025)

    assert_equal 2025, review.year
    assert_equal (1..12).to_a.reverse, review.months.map { |month| month.review.start_date.month }
    assert_equal [ Date.new(2025, 12, 1), Date.new(2025, 1, 1) ], [ review.months.first.review.start_date, review.months.last.review.start_date ]
  end

  test "clamps the year to the year of the oldest entry and the current year" do
    assert_equal 2024, overview(year: 1999).year
    assert_equal 2026, overview(year: 2031).year
  end

  test "starts the oldest year at the month of the oldest entry" do
    months = overview(year: 2024).months

    assert_equal 10, months.size
    assert_equal Date.new(2024, 3, 1), months.last.review.start_date
  end

  test "offers the previous and next year only where they can be reviewed" do
    assert_equal [ 2025, nil ], [ overview.previous_year, overview.next_year ]
    assert_equal [ 2024, 2026 ], [ overview(year: 2025).previous_year, overview(year: 2025).next_year ]
    assert_equal [ nil, 2025 ], [ overview(year: 2024).previous_year, overview(year: 2024).next_year ]
  end

  test "counts each month's reviewable transactions and reviewed ones" do
    user = users(:family_admin)
    create_transaction(account: @account, date: Date.new(2026, 10, 2), name: "Coffee").mark_reviewed!(user)
    create_transaction(account: @account, date: Date.new(2026, 10, 31), name: "Bakery")
    create_transaction(account: @account, date: Date.new(2026, 11, 1), name: "Books")
    create_transaction(account: @account, date: Date.new(2026, 10, 5), name: "Transfer", kind: "funds_movement")
    create_transaction(account: @account, date: Date.new(2026, 10, 6), name: "Excluded", excluded: true)

    november, october, september = overview.months.first(3)

    assert_equal [ 1, 0 ], [ november.progress.total, november.progress.reviewed ]
    assert_equal [ 2, 1 ], [ october.progress.total, october.progress.reviewed ]
    assert_equal 0, september.progress.total
    assert_equal 3, overview(include_transfers: true).months.second.progress.total
  end

  test "counts each entry once when its account is shared with several members" do
    user = users(:family_admin)
    other = @family.users.create!(email: "third@example.com", password: "password123password", first_name: "Third", role: "member")
    AccountShare.create!(account: @account, user: other, permission: "read_write")
    create_transaction(account: @account, date: Date.new(2026, 10, 2), name: "Coffee").mark_reviewed!(user)
    create_transaction(account: @account, date: Date.new(2026, 10, 3), name: "Bakery")

    entries = Current.set(session: user.sessions.create!) { Current.annotatable_entries }
    october = MonthlyReview::Overview.new(@family, entries, today: @today).months.second

    assert_equal [ 2, 1 ], [ october.progress.total, october.progress.reviewed ]
  end

  test "uses the stored review so a completed month shows as completed" do
    MonthlyReview.for(@family, Date.new(2026, 10, 1)).complete!

    october = overview.months.second

    assert october.completed?
    assert_not overview.months.first.completed?
  end

  test "follows a custom month start" do
    @family.update!(month_start_day: 15)

    months = overview.months

    assert_equal [ Date.new(2026, 10, 15), Date.new(2026, 11, 14) ], [ months.first.review.start_date, months.first.review.end_date ]
    assert_equal Date.new(2026, 9, 15), months.second.review.start_date
  end

  test "with a custom month start, a year holds the months labelled in it" do
    @family.update!(month_start_day: 25)
    @today = Date.new(2026, 1, 10)

    assert_equal 2025, overview.year
    assert_equal 2025, overview(year: 2026).year
    assert_equal [ Date.new(2025, 12, 25), Date.new(2026, 1, 24) ], [ overview.months.first.review.start_date, overview.months.first.review.end_date ]
    assert_equal "dec-2025", overview.months.first.review.to_param
    assert_equal Date.new(2025, 1, 25), overview.months.last.review.start_date
  end

  private
    def overview(year: nil, include_transfers: false)
      MonthlyReview::Overview.new(@family, @family.entries, year: year, include_transfers: include_transfers, today: @today)
    end
end
