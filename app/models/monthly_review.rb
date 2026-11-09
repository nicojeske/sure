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

  QUEUE_ORDER = %w[entries.date entries.created_at entries.id].freeze
  private_constant :QUEUE_ORDER
end
