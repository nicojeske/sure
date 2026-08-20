# frozen_string_literal: true

class PaperlessScanAllJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting Paperless receipt scan for all families")

    PaperlessConnection.where(auto_link_enabled: true).find_each do |connection|
      next unless connection.configured?

      # Checked before inserting so the common case doesn't rely on tripping the partial unique
      # index — a failed INSERT would abort the surrounding transaction. The rescue below stays as
      # a backstop for a genuine race with a manual scan.
      next if connection.paperless_scans.in_progress.exists?

      scan = PaperlessScan.create!(
        family_id: connection.family_id,
        paperless_connection: connection,
        trigger: "scheduled"
      )
      PaperlessScanFamilyJob.perform_later(scan.id)
    rescue ActiveRecord::RecordNotUnique
      # A scan is already pending or running for this family (partial unique index) — leave it be.
      Rails.logger.info("Skipping Paperless scan for family #{connection.family_id}: a scan is already in progress")
    rescue => e
      Rails.logger.error("Failed to enqueue Paperless scan for family #{connection.family_id}: #{e.message}")
    end

    Rails.logger.info("Completed Paperless receipt scan enqueue")
  end
end
