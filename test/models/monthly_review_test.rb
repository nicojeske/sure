require "test_helper"

class MonthlyReviewTest < ActiveSupport::TestCase
  include EntriesTestHelper, ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @family.accounts.each { |account| account.entries.delete_all }
    @review = MonthlyReview.for(@family, Date.new(2026, 10, 15))
  end

  test "for covers the calendar month and is idempotent" do
    assert_equal Date.new(2026, 10, 1), @review.start_date
    assert_equal Date.new(2026, 10, 31), @review.end_date
    assert_equal "oct-2026", @review.to_param
    assert_equal @review, MonthlyReview.for(@family, Date.new(2026, 10, 3))
  end

  test "for honours a custom month start" do
    @family.update!(month_start_day: 15)

    review = MonthlyReview.for(@family, Date.new(2026, 10, 3))

    assert_equal Date.new(2026, 9, 15), review.start_date
    assert_equal Date.new(2026, 10, 14), review.end_date
  end

  test "month entries keep only reviewable transactions of the month in date order" do
    late = create_transaction(account: @account, date: Date.new(2026, 10, 20), name: "Late")
    early = create_transaction(account: @account, date: Date.new(2026, 10, 2), name: "Early")
    create_transaction(account: @account, date: Date.new(2026, 11, 1), name: "Next month")
    create_transaction(account: @account, date: Date.new(2026, 10, 5), name: "Excluded", excluded: true)
    transfer = create_transaction(account: @account, date: Date.new(2026, 10, 6), name: "Transfer", kind: "funds_movement")
    create_valuation(account: @account, date: Date.new(2026, 10, 7))

    assert_equal [ early, late ], @review.month_entries(@family.entries).to_a
    assert_equal [ early, transfer, late ], @review.month_entries(@family.entries, include_transfers: true).to_a
  end

  test "month entries skip pending transactions" do
    pending_entry = create_transaction(account: @account, date: Date.new(2026, 10, 2))
    pending_entry.transaction.update!(extra: { "simplefin" => { "pending" => true } })
    posted = create_transaction(account: @account, date: Date.new(2026, 10, 3))

    assert_equal [ posted ], @review.month_entries(@family.entries).to_a
  end

  test "split parts are reviewed individually and the parent is left out" do
    parent = create_transaction(account: @account, date: Date.new(2026, 10, 2), amount: 100)
    children = parent.split!([ { name: "A", amount: 60 }, { name: "B", amount: 40 } ])

    assert_equal children.map(&:id).sort, @review.month_entries(@family.entries).map(&:id).sort
  end

  test "queue navigation moves forward over unreviewed and back over everything" do
    first = create_transaction(account: @account, date: Date.new(2026, 10, 1))
    second = create_transaction(account: @account, date: Date.new(2026, 10, 2))
    third = create_transaction(account: @account, date: Date.new(2026, 10, 3))
    second.mark_reviewed!(users(:family_admin))
    entries = @family.entries

    assert_equal first, @review.next_entry_after(nil, entries)
    assert_equal third, @review.next_entry_after(first, entries)
    assert_nil @review.next_entry_after(third, entries)
    assert_equal second, @review.previous_entry_before(third, entries)
    assert_nil @review.previous_entry_before(first, entries)
  end

  test "progress counts reviewed entries" do
    reviewed = create_transaction(account: @account, date: Date.new(2026, 10, 1))
    create_transaction(account: @account, date: Date.new(2026, 10, 2))
    reviewed.mark_reviewed!(users(:family_admin))

    progress = @review.progress(@family.entries)

    assert_equal 2, progress.total
    assert_equal 1, progress.reviewed
    assert_equal 1, progress.remaining
    assert_not progress.done?
  end

  test "queue respects the caller's access scope" do
    create_transaction(account: accounts(:other_asset), date: Date.new(2026, 10, 1))
    member = users(:family_member)
    visible = @family.entries.joins(:account).merge(Account.annotatable_by(member))

    assert_empty @review.queue(visible).where(account: accounts(:other_asset))
  end

  test "complete and reopen" do
    @review.complete!
    assert @review.completed?

    @review.reopen!
    assert_not @review.completed?
  end

  test "prefetch_suggestions_later enqueues once per interval unless forced" do
    user = users(:family_admin)

    assert_enqueued_with(job: MonthlyReview::PrefetchSuggestionsJob, args: [ @review, user, { include_transfers: true } ]) do
      assert @review.prefetch_suggestions_later(user, include_transfers: true)
    end
    assert_not_nil @review.prefetched_at

    assert_no_enqueued_jobs(only: MonthlyReview::PrefetchSuggestionsJob) do
      assert_not MonthlyReview.find(@review.id).prefetch_suggestions_later(user)
    end

    assert_enqueued_jobs(1, only: MonthlyReview::PrefetchSuggestionsJob) do
      assert @review.prefetch_suggestions_later(user, force: true)
    end

    travel MonthlyReview::PREFETCH_INTERVAL + 1.minute do
      assert_enqueued_jobs(1, only: MonthlyReview::PrefetchSuggestionsJob) do
        assert @review.prefetch_suggestions_later(user)
      end
    end
  end
end
