# One family's review of one budget month: the note written at the end and
# whether the month was signed off. Per-transaction progress lives on
# entries.reviewed_at, so the queue is always derived, never stored.
class MonthlyReview < ApplicationRecord
  belongs_to :family

  validates :start_date, :end_date, presence: true
  validates :start_date, uniqueness: { scope: :family_id }

  class << self
    # Finds or creates the review for the budget month containing `date`,
    # honouring the family's custom month start.
    def for(family, date)
      start_date, end_date = Budget.period_for(date, family: family)
      family.monthly_reviews.find_by(start_date: start_date) ||
        family.monthly_reviews.create_or_find_by!(start_date: start_date) { |review| review.end_date = end_date }
    end
  end

  def to_param
    Budget.date_to_param(start_date)
  end

  # Every transaction entry of the month that belongs in a review, reviewed or
  # not. `entries` is the caller's access-scoped relation (normally
  # Current.annotatable_entries) so share permissions stay with the caller.
  def month_entries(entries, include_transfers: false)
    scope = entries
      .where(entryable_type: "Transaction", date: start_date..end_date, excluded: false)
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
      .merge(Entry.excluding_split_parents)
      .merge(Entry.excluding_pending)

    scope = scope.where.not(transactions: { kind: Transaction::TRANSFER_KINDS }) unless include_transfers
    scope.order(*QUEUE_ORDER)
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
    scope = month_entries(entries, include_transfers: include_transfers).unscope(:order)
    Progress.new(total: scope.count, reviewed: scope.reviewed.count)
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

  def prefetch_suggestions(user, include_transfers: false, retry_failed: false, &block)
    SuggestionPrefetch.new(self, user: user, include_transfers: include_transfers, retry_failed: retry_failed).run(&block)
  end

  # Undoes a card's review (Q15): reverts the proposal that marked it reviewed,
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

  def complete!
    update!(completed_at: Time.current)
  end

  def reopen!
    update!(completed_at: nil)
  end

  Progress = Data.define(:total, :reviewed) do
    def remaining = total - reviewed
    def done? = remaining.zero?
  end

  PREFETCH_INTERVAL = 10.minutes

  QUEUE_ORDER = %w[entries.date entries.created_at entries.id].freeze
  private_constant :QUEUE_ORDER
end
