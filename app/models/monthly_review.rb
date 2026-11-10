# One family's review of one budget month: the note written at the end and
# whether the month was signed off. Per-transaction progress lives on
# entries.reviewed_at, so the queue is always derived, never stored.
class MonthlyReview < ApplicationRecord
  belongs_to :family

  validates :start_date, :end_date, presence: true
  validates :start_date, uniqueness: { scope: :family_id }

  class << self
    # Whether `user` may write a review's note and complete it: the people
    # who review, so not guests and not members who can only read shared
    # accounts.
    def editable_by?(user)
      !user.guest? && user.family.accounts.annotatable_by(user).exists?
    end

    # Finds or creates the review for the budget month containing `date`,
    # honouring the family's custom month start.
    def for(family, date)
      start_date, end_date = Budget.period_for(date, family: family)
      family.monthly_reviews.find_by(start_date: start_date) ||
        family.monthly_reviews.create_or_find_by!(start_date: start_date) { |review| review.end_date = end_date }
    end

    # Whether the month containing `date` can be opened: the months budgets
    # cover, plus the one holding the oldest entry, which budgets leave out
    # when a custom month start makes it begin before that entry's calendar
    # month.
    def reviewable_month?(family, date)
      Budget.budget_date_valid?(date, family: family) ||
        Budget.period_for(date, family: family) == Budget.period_for(family.oldest_entry_date, family: family)
    end

    # The stored review of the month containing `date`, else an unsaved one,
    # for pages that only read it.
    def find_or_build(family, date)
      start_date, end_date = Budget.period_for(date, family: family)
      family.monthly_reviews.find_by(start_date: start_date) ||
        new(family_id: family.id, start_date: start_date, end_date: end_date)
    end

    # The transaction entries in `dates` that belong in a review, unordered.
    # `entries` is the caller's access-scoped relation.
    def reviewable_entries(entries, dates, include_transfers: false)
      scope = entries
        .where(entryable_type: "Transaction", date: dates, excluded: false)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .merge(Entry.excluding_split_parents)
        .merge(Entry.excluding_pending)

      include_transfers ? scope : scope.where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
    end

    # { date => Progress } for the reviewable entries in `dates`. Counts are
    # distinct because access-scoped relations join account shares.
    def progress_by_date(entries, dates, include_transfers: false)
      reviewable_entries(entries, dates, include_transfers: include_transfers)
        .group("entries.date")
        .pluck(
          Arel.sql("entries.date"),
          Arel.sql("COUNT(DISTINCT entries.id)"),
          Arel.sql("COUNT(DISTINCT entries.id) FILTER (WHERE entries.reviewed_at IS NOT NULL)")
        )
        .to_h { |date, total, reviewed| [ date, Progress.new(total: total, reviewed: reviewed) ] }
    end
  end

  def to_param
    Budget.date_to_param(start_date)
  end

  # Every transaction entry of the month that belongs in a review, reviewed or
  # not. `entries` is the caller's access-scoped relation (normally
  # Current.annotatable_entries) so share permissions stay with the caller.
  def month_entries(entries, include_transfers: false)
    self.class.reviewable_entries(entries, period.date_range, include_transfers: include_transfers).order(*QUEUE_ORDER)
  end

  def period
    Period.custom(start_date: start_date, end_date: end_date)
  end

  def queue(entries, include_transfers: false)
    month_entries(entries, include_transfers: include_transfers).unreviewed
  end

  # Next unreviewed entry after `entry`, or the first unreviewed one when
  # `entry` is nil. Skipped entries stay behind the cursor until the queue
  # is restarted.
  def next_entry_after(entry, entries, include_transfers: false)
    scope = queue(entries, include_transfers: include_transfers)
    scope = scope.where("(entries.date, entries.created_at, entries.id) > (?, ?, ?)", entry.date, entry.created_at, entry.id) if entry
    scope.first
  end

  # Going back includes reviewed entries so an accepted card can be revisited
  # and undone.
  def previous_entry_before(entry, entries, include_transfers: false)
    month_entries(entries, include_transfers: include_transfers)
      .where("(entries.date, entries.created_at, entries.id) < (?, ?, ?)", entry.date, entry.created_at, entry.id)
      .reorder(QUEUE_ORDER.map { |column| "#{column} DESC" })
      .first
  end

  def progress(entries, include_transfers: false)
    progress_from(self.class.progress_by_date(entries, period.date_range, include_transfers: include_transfers))
  end

  # This month's progress out of `progress_by_date` counts that may cover
  # more than the month.
  def progress_from(progress_by_date)
    Progress.sum(progress_by_date.filter_map { |date, progress| progress if date.between?(start_date, end_date) })
  end

  # Queues a background run of receipt-backed suggestions for `user`'s queue.
  # Opening the review only starts one when the last run began more than
  # PREFETCH_INTERVAL ago; `force` (the refresh button) always does and also
  # retries failed suggestions. Returns whether a job was enqueued.
  def prefetch_suggestions_later(user, include_transfers: false, force: false)
    now = Time.current
    claim = self.class.where(id: id)
    claim = claim.where("prefetched_at IS NULL OR prefetched_at < ?", now - PREFETCH_INTERVAL) unless force
    return false unless claim.update_all(prefetched_at: now) == 1

    self.prefetched_at = now
    clear_attribute_changes([ :prefetched_at ])
    PrefetchSuggestionsJob.perform_later(self, user, include_transfers: include_transfers, force: force)
    true
  end

  def prefetch_suggestions(user, include_transfers: false, retry_failed: false, limit: SuggestionPrefetch::LIMIT, &block)
    SuggestionPrefetch.new(self, user: user, include_transfers: include_transfers, retry_failed: retry_failed, limit: limit).run(&block)
  end

  # Whether proposals can be built at all: a Paperless connection to read
  # receipts from and an LLM provider to read them.
  def suggestions_available?
    family.paperless_configured? && Provider::Registry.preferred_llm_provider.present?
  end

  # Starts reading the entry's receipt in the background when the card has a
  # usable receipt and nothing else to show. The claim keeps it from running
  # twice alongside the prefetch. Returns the claimed pending suggestion, or
  # nil when there was nothing to start.
  def read_receipt_later(entry, user)
    return nil if entry.reviewed? || !suggestions_available?

    link = Transaction::AnnotationSuggester.receipt_choice(entry.transaction).link
    return nil if link.nil? || link.paperless_connection_id != family.paperless_connection.id
    return nil if entry.annotation_suggestions.hint.not_edited.where(status: MonthlyReview::Card::OPEN_STATUSES).exists?

    suggestion = TransactionAnnotationSuggestion.claim_for(
      entry, input_hash: Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: link),
      family: family, source: "receipt", receipt_link: link
    )
    ReadReceiptJob.perform_later(suggestion, user) if suggestion
    suggestion
  end

  # The month's entries for the card page, loaded once.
  def card_list(entries, include_transfers: false)
    CardList.new(month_entries(entries, include_transfers: include_transfers).preload(:account, entryable: [ :merchant, :receipt_links ]), family: family)
  end

  # Undoes a card's review: reverts the proposal that marked it reviewed,
  # or only clears "reviewed" when it was marked without one. Undoing a split
  # part reverts the split, which removes the part. Returns the entry the
  # review continues with: `entry`, or its split parent.
  def undo_review!(entry, user)
    return entry unless entry.reviewed?

    if (suggestion = TransactionAnnotationSuggestion.applied_in_review_of(entry))
      suggestion.revert!(user: user)
      suggestion.entry
    else
      entry.unmark_reviewed!
      entry
    end
  end

  def completed?
    completed_at.present?
  end

  # :completed, :empty (nothing to review), :ready (all reviewed, not yet
  # completed), :in_progress or :not_started.
  def status(progress)
    if completed? then :completed
    elsif progress.total.zero? then :empty
    elsif progress.done? then :ready
    elsif progress.reviewed.positive? then :in_progress
    else :not_started
    end
  end

  def complete!
    update!(completed_at: Time.current)
  end

  def reopen!
    update!(completed_at: nil)
  end

  Progress = Data.define(:total, :reviewed) do
    def self.sum(progresses)
      new(total: progresses.sum(&:total), reviewed: progresses.sum(&:reviewed))
    end

    def remaining = total - reviewed
    def percent = total.zero? ? 0 : reviewed * 100 / total
    def done? = remaining.zero?
  end

  PREFETCH_INTERVAL = 10.minutes

  QUEUE_ORDER = %w[entries.date entries.created_at entries.id].freeze
  private_constant :QUEUE_ORDER
end
