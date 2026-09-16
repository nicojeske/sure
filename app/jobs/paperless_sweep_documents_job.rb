# frozen_string_literal: true

# The reverse of PaperlessScanFamilyJob: walks Paperless's documents (newest-added first) instead
# of the family's transactions, using PaperlessConnection::DocumentMatcher to find and link/suggest
# a local transaction for each one. This is the only way a backlog of historical receipts —
# uploaded to Paperless long after the transactions they belong to — ever gets matched; see
# docs/hosting/paperless.md.
class PaperlessSweepDocumentsJob < ApplicationJob
  include PaperlessScanReporting

  queue_as :low_priority

  # Progress pushes, not one per document — matches PaperlessScanFamilyJob's cadence.
  BROADCAST_EVERY = 10

  # A dead or misconfigured Paperless fails identically for every document; stop rather than spend
  # the whole run proving it.
  ABORT_AFTER_CONSECUTIVE_ERRORS = 5
  FATAL_ERROR_TYPES = %i[unauthorized untrusted_host].freeze

  MAX_DOCUMENTS_PER_RUN = 2000
  # Search results carry the full OCR `content` field, so a smaller page than the provider's
  # default keeps individual responses reasonable.
  PAGE_SIZE = 50

  def perform(paperless_scan_id)
    scan = PaperlessScan.find_by(id: paperless_scan_id)
    # Also guards a Sidekiq retry of an already-finished scan.
    return unless scan&.pending?

    connection = scan.paperless_connection
    # No auto_link_enabled gate here: that toggle governs only whether PaperlessSweepAllJob
    # enqueues a nightly sweep. An explicitly requested sweep always runs.
    return fail_scan!(scan, "Paperless connection is not configured") unless connection.configured?

    scan.update!(status: "running", started_at: Time.current)
    broadcast_progress(scan)

    run(scan, connection)
  end

  private
    def run(scan, connection)
      matcher = PaperlessConnection::DocumentMatcher.new(connection)
      already_linked = connection.receipt_links.linked.distinct.pluck(:document_id).to_set
      consecutive_errors = 0
      page = 1
      total_recorded = false

      loop do
        response = provider(connection).search_documents(page: page, page_size: PAGE_SIZE, ordering: "-added", added_from: scan.added_from)
        documents = response["results"] || []

        unless total_recorded
          record_total(scan, response["count"].to_i)
          total_recorded = true
        end

        documents.each do |document|
          break if scan.processed_count >= scan.total_count

          if already_linked.include?(document["id"])
            scan.increment!(:processed_count)
            next
          end

          begin
            result = matcher.match!(document)
            consecutive_errors = 0
            tally(scan, result.outcome)
          rescue Provider::Paperless::Error => e
            consecutive_errors += 1
            scan.increment!(:error_count)
            log_document_error(scan, document, e)

            if FATAL_ERROR_TYPES.include?(e.error_type) || consecutive_errors >= ABORT_AFTER_CONSECUTIVE_ERRORS
              return fail_scan!(scan, e.message)
            end
          end

          scan.increment!(:processed_count)
          broadcast_progress(scan) if (scan.processed_count % BROADCAST_EVERY).zero?
        end

        break if documents.size < PAGE_SIZE || scan.processed_count >= scan.total_count
        page += 1
      end

      complete_scan!(scan)
    rescue StandardError => e
      fail_scan!(scan, e.message)
      raise
    end

    def record_total(scan, real_count)
      capped = real_count > MAX_DOCUMENTS_PER_RUN
      scan.update!(total_count: capped ? MAX_DOCUMENTS_PER_RUN : real_count, capped: capped)
    end

    def tally(scan, outcome)
      case outcome
      when :linked    then scan.increment!(:linked_count)
      when :suggested then scan.increment!(:suggested_count)
      end
    end

    def provider(connection)
      @provider ||= Provider::Paperless.new(
        base_url: connection.base_url,
        api_token: connection.api_token,
        verify_ssl: connection.verify_ssl
      )
    end

    def log_document_error(scan, document, error)
      log_scan_error(scan, error, document_id: document["id"])
    end
end
