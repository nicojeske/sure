# The bill suggestion a review card offers for its entry, read from the
# recurring series that already cover it: an active bill is shown as context,
# a suggested series can be confirmed or dismissed. Nothing is detected here;
# without such a series there is no suggestion.
class MonthlyReview::BillSuggestion
  STATUSES = %w[active suggested].freeze

  attr_reader :series

  # The suggestion for this entry as the user sees it, or nil.
  def self.for(entry, user:)
    series = entry.account.family.recurring_transactions.accessible_by(user).covering(entry)
    new(series) if series&.status.in?(STATUSES)
  end

  def initialize(series)
    @series = series
  end

  delegate :active?, :suggested?, :display_name, to: :series
end
