# The month's entries as the card page lists them beside the card, in queue
# order: which entry the card shows, where it sits and each row's status.
class MonthlyReview::CardList
  include Enumerable

  attr_reader :entries

  def initialize(entries)
    @entries = entries.to_a
  end

  def each(&block)
    entries.each(&block)
  end

  def size
    entries.size
  end

  # The entry named by the URL, else the first unreviewed one; nil when
  # everything is reviewed.
  def current_entry(entry_id: nil)
    return entries.find { |entry| entry.id == entry_id } || raise(ActiveRecord::RecordNotFound) if entry_id.present?

    first_unreviewed
  end

  def first_unreviewed
    entries.find { |entry| !entry.reviewed? }
  end

  def next_unreviewed_after(entry)
    entries.drop(index_of(entry) + 1).find { |candidate| !candidate.reviewed? }
  end

  def position(entry)
    index_of(entry) + 1
  end

  def first?(entry)
    index_of(entry).zero?
  end

  def reviewed_ids
    entries.select(&:reviewed?).map(&:id)
  end

  # The entries around `entry`, for the phone strip.
  def around(entry, before: 2, count: 6)
    entries[[ index_of(entry) - before, 0 ].max, count] || []
  end

  # current, reviewed or open. Skips aren't stored, so an entry passed over
  # stays open.
  def status(entry, current)
    return "current" if entry == current

    entry.reviewed? ? "reviewed" : "open"
  end

  private
    def index_of(entry)
      @index ||= entries.each_with_index.to_h { |candidate, index| [ candidate.id, index ] }
      @index.fetch(entry.id)
    end
end
