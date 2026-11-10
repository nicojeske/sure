# Builds receipt-backed annotation proposals ahead of time for the unreviewed
# entries of one review month, so cards with a receipt open with their
# proposal ready. Only entries with a linked or clear-cut suggested receipt
# are covered; hints and close receipt candidates need the user.
#
# Prefetch runs never send the same receipt to the LLM twice at once or after
# it has a result: each entry is claimed through
# TransactionAnnotationSuggestion.claim_for, which skips ready, applied,
# reverted and in-flight rows. A stale pending row (its run died) is taken
# over, and a failed one is retried only when `retry_failed` (the refresh
# button; a Time retries only rows that failed before it). The card can
# still re-run a stale pending or failed row itself.
class MonthlyReview::SuggestionPrefetch
  LIMIT = 200
  # LLM failures in a row after which the provider is most likely down or
  # misconfigured. Paperless and receipt failures do not count.
  MAX_CONSECUTIVE_FAILURES = 3

  attr_reader :review, :user, :include_transfers, :retry_failed, :limit

  def initialize(review, user:, include_transfers: false, retry_failed: false, limit: LIMIT)
    @review = review
    @user = user
    @include_transfers = include_transfers
    @retry_failed = retry_failed
    @limit = limit
  end

  # Returns the suggestions it ran, in queue order, and yields each with its
  # entry as soon as it is finished.
  def run
    return [] unless runnable?

    suggestions = []
    failures = 0

    runnable_candidates.each do |entry, receipt_link|
      break if suggestions.size >= limit
      next unless claim(entry, receipt_link)

      suggestion = suggester.suggest_from_receipt(entry, receipt_link)
      suggestions << suggestion
      yield entry, suggestion if block_given?

      if suggestion.failed? && Transaction::AnnotationSuggester.llm_failure?(suggester.last_error)
        failures += 1
        if failures >= MAX_CONSECUTIVE_FAILURES
          capture_breaker_trip(failures)
          break
        end
      elsif !suggestion.failed?
        failures = 0
      end
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
      review.suggestions_available?
    end

    # [entry, receipt_link] pairs whose receipt has no suggestion yet or one
    # this run may take over, found with one lookup for the whole queue.
    def runnable_candidates
      pairs = candidates.filter_map do |entry|
        link = Transaction::AnnotationSuggester.receipt_choice(entry.transaction).link
        [ entry, link ] if link
      end

      hashes = pairs.to_h { |entry, link| [ entry.id, input_hash(link) ] }
      existing = TransactionAnnotationSuggestion
        .where(entry_id: hashes.keys, input_hash: hashes.values)
        .index_by { |suggestion| [ suggestion.entry_id, suggestion.input_hash ] }

      pairs.select do |entry, link|
        suggestion = existing[[ entry.id, hashes[entry.id] ]]
        suggestion.nil? || suggestion.reclaimable?(retry_failed: retry_failed)
      end
    end

    def candidates
      entries = family.entries.joins(:account).merge(Account.annotatable_by(user))
      receipt_backed = ReceiptLink.where(paperless_connection: connection, status: %w[linked suggested]).select(:transaction_id)

      review.queue(entries, include_transfers: include_transfers)
        .where(entryable_id: receipt_backed)
        .preload(:account, entryable: { receipt_links: :paperless_connection })
    end

    def claim(entry, receipt_link)
      TransactionAnnotationSuggestion.claim_for(
        entry,
        input_hash: input_hash(receipt_link), retry_failed: retry_failed,
        family: family, source: "receipt", receipt_link: receipt_link
      )
    end

    def input_hash(receipt_link)
      Transaction::AnnotationSuggester.input_hash(:receipt, receipt_link: receipt_link)
    end

    def suggester
      @suggester ||= Transaction::AnnotationSuggester.new(family, user: user)
    end

    def capture_breaker_trip(failures)
      error = suggester.last_error

      DebugLogEntry.capture(
        category: "ai_annotation",
        level: "error",
        message: "Monthly review prefetch stopped after #{failures} LLM failures in a row: #{error.class}: #{error.message}",
        source: self.class.name,
        family: family,
        user: user,
        provider_key: suggester.llm_provider_key,
        metadata: {
          monthly_review_id: review.id,
          consecutive_failures: failures,
          last_error_class: error.class.name,
          last_error: error.message.to_s.truncate(500)
        }
      )
    end
end
