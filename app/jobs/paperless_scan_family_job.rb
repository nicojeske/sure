# frozen_string_literal: true

# Runs one family-wide Paperless receipt scan, sequentially, reporting live progress onto its
# PaperlessScan row and out to the family's Turbo Stream.
#
# Sequential rather than fanning out one PaperlessAutoLinkJob per transaction: a single loop can
# report progress at all, and it reuses one Matcher, whose memoized `correspondents` and
# `custom_fields` would otherwise be refetched from Paperless for every transaction.
class PaperlessScanFamilyJob < ApplicationJob
  queue_as :low_priority

  # Progress pushes, not one per transaction — 500 broadcasts would swamp the stream.
  BROADCAST_EVERY = 10

  # A dead or misconfigured Paperless fails identically for every transaction; stop rather than
  # spend 500 requests proving it.
  ABORT_AFTER_CONSECUTIVE_ERRORS = 5
  FATAL_ERROR_TYPES = %i[unauthorized untrusted_host].freeze

  def perform(paperless_scan_id)
    scan = PaperlessScan.find_by(id: paperless_scan_id)
    # Also guards a Sidekiq retry of an already-finished scan.
    return unless scan&.pending?

    connection = scan.paperless_connection
    # No auto_link_enabled gate here: that toggle governs only whether PaperlessScanAllJob
    # enqueues a nightly scan. An explicitly requested scan always runs.
    return fail_scan!(scan, "Paperless connection is not configured") unless connection.configured?

    transactions = load_transactions(connection)
    scan.update!(
      status: "running",
      started_at: Time.current,
      total_count: transactions.size,
      capped: @capped
    )
    broadcast_progress(scan)

    run(scan, connection, transactions)
  end

  private
    def load_transactions(connection)
      limit = PaperlessConnection::MAX_TRANSACTIONS_PER_RUN
      transactions = connection.transactions_needing_scan
        .includes(entry: :account)
        .limit(limit + 1)
        .to_a

      @capped = transactions.size > limit
      @capped ? transactions.first(limit) : transactions
    end

    def run(scan, connection, transactions)
      matcher = PaperlessConnection::Matcher.new(connection)
      consecutive_errors = 0

      transactions.each do |transaction|
        begin
          result = matcher.match!(transaction)
          consecutive_errors = 0
          tally(scan, result.outcome)
        rescue Provider::Paperless::Error => e
          consecutive_errors += 1
          scan.increment!(:error_count)
          log_transaction_error(scan, transaction, e)

          if FATAL_ERROR_TYPES.include?(e.error_type) || consecutive_errors >= ABORT_AFTER_CONSECUTIVE_ERRORS
            return fail_scan!(scan, e.message)
          end
        end

        scan.increment!(:processed_count)
        broadcast_progress(scan) if (scan.processed_count % BROADCAST_EVERY).zero?
      end

      complete_scan!(scan)
    rescue StandardError => e
      fail_scan!(scan, e.message)
      raise
    end

    def tally(scan, outcome)
      case outcome
      when :linked    then scan.increment!(:linked_count)
      when :suggested then scan.increment!(:suggested_count)
      end
    end

    def complete_scan!(scan)
      scan.update!(status: "completed", completed_at: Time.current)
      finish(scan)
    end

    def fail_scan!(scan, message)
      scan.update!(status: "failed", error: message, completed_at: Time.current)
      finish(scan)
      nil
    end

    def finish(scan)
      broadcast_progress(scan)

      # The match list itself can't be broadcast: it's scoped by Account.accessible_by(Current.user)
      # and Current.user is nil in a job. A morph refresh re-renders each viewer's page in their own
      # request context, so the new rows show up with the right permissions.
      scan.family.broadcast_refresh
    end

    def broadcast_progress(scan)
      Turbo::StreamsChannel.broadcast_replace_to(
        scan.family,
        target: "paperless_scan_status",
        partial: "receipts/scan_status",
        locals: { scan: scan }
      )
    end

    def log_transaction_error(scan, transaction, error)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless scan failed for a transaction: #{error.message}",
        source: self.class.name,
        provider_key: "paperless",
        family: scan.family,
        metadata: {
          error_type: error.error_type,
          transaction_id: transaction.id,
          paperless_scan_id: scan.id
        }
      )
    end
end
