# frozen_string_literal: true

class PaperlessScanAllJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    Rails.logger.info("Starting Paperless receipt scan for all families")

    PaperlessConnection.where(auto_link_enabled: true).find_each do |connection|
      next unless connection.configured?

      PaperlessScanFamilyJob.perform_later(connection.family_id)
    rescue => e
      Rails.logger.error("Failed to enqueue Paperless scan for family #{connection.family_id}: #{e.message}")
    end

    Rails.logger.info("Completed Paperless receipt scan enqueue")
  end
end
