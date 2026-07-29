# frozen_string_literal: true

class PaperlessScanFamilyJob < ApplicationJob
  queue_as :low_priority

  MAX_TRANSACTIONS_PER_RUN = 500
  LOOKBACK_WINDOW = 90.days
  RESCAN_AFTER = 7.days

  def perform(family_id)
    family = Family.find_by(id: family_id)
    return unless family

    connection = family.paperless_connection
    return unless connection&.configured? && connection.auto_link_enabled?

    transactions = transactions_needing_scan(family).limit(MAX_TRANSACTIONS_PER_RUN + 1).to_a

    if transactions.size > MAX_TRANSACTIONS_PER_RUN
      Rails.logger.info(
        "PaperlessScanFamilyJob: family #{family.id} has more than #{MAX_TRANSACTIONS_PER_RUN} " \
        "transactions needing a receipt scan; capping this run"
      )
      transactions = transactions.first(MAX_TRANSACTIONS_PER_RUN)
    end

    transactions.each do |transaction|
      PaperlessAutoLinkJob.perform_later(transaction.id)
    end
  end

  private
    # receipt_scanned_at IS NULL (never scanned), or it's stale (> RESCAN_AFTER) and
    # nothing is linked yet — a receipt is often filed in Paperless days after the
    # transaction posts, so a one-shot scan would permanently miss it.
    def transactions_needing_scan(family)
      family.transactions
        .joins(:entry)
        .where(entries: { date: LOOKBACK_WINDOW.ago.to_date.. })
        .where.not(kind: Transaction::TRANSFER_KINDS)
        .where(
          "transactions.receipt_scanned_at IS NULL OR (transactions.receipt_scanned_at < :rescan_before AND NOT EXISTS (" \
          "SELECT 1 FROM receipt_links WHERE receipt_links.transaction_id = transactions.id AND receipt_links.status = 'linked'))",
          rescan_before: RESCAN_AFTER.ago
        )
    end
end
