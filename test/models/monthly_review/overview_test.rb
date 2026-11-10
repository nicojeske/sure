require "test_helper"

class MonthlyReview::OverviewTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }
    @today = Date.new(2026, 11, 10)
  end

  test "lists the last twelve months, newest first, without creating reviews" do
    assert_no_difference "MonthlyReview.count" do
      months = overview.months

      assert_equal 12, months.size
      assert_equal Date.new(2026, 11, 1), months.first.review.start_date
      assert_equal Date.new(2025, 12, 1), months.last.review.start_date
      assert_equal Date.new(2025, 12, 31), months.last.review.end_date
      assert_equal "nov-2026", months.first.review.to_param
    end
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

  private
    def overview(include_transfers: false)
      MonthlyReview::Overview.new(@family, @family.entries, include_transfers: include_transfers, today: @today)
    end
end
