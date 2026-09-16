# frozen_string_literal: true

# Nightly counterpart to PaperlessScanAllJob, but for the document-first direction: enqueues one
# PaperlessSweepDocumentsJob per family with auto-linking enabled, bounded to documents added
# recently (added_from) so the nightly run stays cheap. A family with a real backlog of much older
# receipts (e.g. a bulk upload) uses the unbounded manual "Match unlinked receipts" button on
# /receipts instead — see docs/hosting/paperless.md.
class PaperlessSweepAllJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Comfortably wider than the daily cron interval so a slow day (a worker outage, a delayed run)
  # doesn't let a document slip through uncovered.
  ADDED_LOOKBACK = 14.days

  def perform
    Rails.logger.info("Starting Paperless document sweep for all families")

    PaperlessConnection.where(auto_link_enabled: true).find_each do |connection|
      next unless connection.configured?

      # Checked before inserting so the common case doesn't rely on tripping the partial unique
      # index — a failed INSERT would abort the surrounding transaction. The rescue below stays as
      # a backstop for a genuine race with a manual scan/sweep.
      next if connection.paperless_scans.in_progress.exists?

      scan = PaperlessScan.create!(
        family_id: connection.family_id,
        paperless_connection: connection,
        trigger: "scheduled",
        mode: "documents",
        added_from: ADDED_LOOKBACK.ago.to_date
      )
      PaperlessSweepDocumentsJob.perform_later(scan.id)
    rescue ActiveRecord::RecordNotUnique
      # A scan or sweep is already pending or running for this family (partial unique index) —
      # leave it be.
      Rails.logger.info("Skipping Paperless sweep for family #{connection.family_id}: a scan is already in progress")
    rescue => e
      Rails.logger.error("Failed to enqueue Paperless sweep for family #{connection.family_id}: #{e.message}")
    end

    Rails.logger.info("Completed Paperless document sweep enqueue")
  end
end
