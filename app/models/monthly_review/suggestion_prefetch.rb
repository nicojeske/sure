# Builds receipt-backed annotation proposals ahead of time for the unreviewed
# entries of one review month, so cards with a receipt open with their
# proposal ready. Only entries with a linked or clear-cut suggested receipt
# are covered; hints and close receipt candidates need the user.
#
# Each input reaches the LLM at most once: an entry is claimed by inserting
# its pending suggestion row (unique on entry and input), and any existing
# row for that receipt (ready, applied, failed or still in flight) is left
# alone. A failed proposal is retried from the card, not here.
class MonthlyReview::SuggestionPrefetch
  LIMIT = 200
  # A provider that keeps failing is most likely down or misconfigured.
  MAX_CONSECUTIVE_FAILURES = 3

  attr_reader :review, :user, :include_transfers, :limit

  def initialize(review, user:, include_transfers: false, limit: LIMIT)
    @review = review
    @user = user
    @include_transfers = include_transfers
    @limit = limit
  end

  # Returns the suggestions it ran, in queue order, and yields each with its
  # entry as soon as it is finished.
  def run
    return [] unless runnable?

    suggestions = []
    failures = 0

    candidates.each do |entry|
      break if suggestions.size >= limit || failures >= MAX_CONSECUTIVE_FAILURES

      receipt_link = Transaction::AnnotationSuggester.receipt_choice(entry.transaction).link
      next unless receipt_link && claim(entry, receipt_link)

      suggestion = suggester.suggest_from_receipt(entry, receipt_link)
      failures = suggestion.failed? ? failures + 1 : 0
      suggestions << suggestion
      yield entry, suggestion if block_given?
    end

    suggestions
  end

  private
    def family
      review.family
    end

    def connection
      family.paperless_connection
    end

    def runnable?
      connection&.configured? && Provider::Registry.preferred_llm_provider.present?
    end

    def candidates
      entries = family.entries.joins(:account).merge(Account.annotatable_by(user))
      receipt_backed = ReceiptLink.where(paperless_connection: connection, status: %w[linked suggested]).select(:transaction_id)

      review.queue(entries, include_transfers: include_transfers)
        .where(entryable_id: receipt_backed)
        .preload(:account, :entryable)
    end

    def claim(entry, receipt_link)
      input_hash = Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: receipt_link)
      return false if TransactionAnnotationSuggestion.exists?(entry_id: entry.id, input_hash: input_hash)

      TransactionAnnotationSuggestion.transaction(requires_new: true) do
        TransactionAnnotationSuggestion.create!(
          entry: entry, family: family, input_hash: input_hash,
          source: "receipt", status: "pending", receipt_link: receipt_link
        )
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end

    def suggester
      @suggester ||= Transaction::AnnotationSuggester.new(family, user: user)
    end
end
