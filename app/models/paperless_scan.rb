# frozen_string_literal: true

# One run of the family-wide Paperless receipt scan, whether triggered by the nightly
# PaperlessScanAllJob or by hand from /receipts. Exists so a run has live progress (the counters
# below are what PaperlessScanFamilyJob broadcasts) and so its outcome survives a page reload.
class PaperlessScan < ApplicationRecord
  # A job that dies mid-run (worker restart, OOM) leaves its row `running` forever, which the
  # partial unique index would otherwise turn into a permanent "a scan is already running".
  STALE_AFTER = 30.minutes

  belongs_to :family
  belongs_to :paperless_connection

  scope :recent, -> { order(created_at: :desc) }
  scope :in_progress, -> { where(status: %w[pending running]) }

  def pending? = status == "pending"
  def running? = status == "running"
  def completed? = status == "completed"
  def failed? = status == "failed"
  def in_progress? = pending? || running?
  def documents_mode? = mode == "documents"

  def stale? = in_progress? && (started_at || created_at) < STALE_AFTER.ago

  def percent
    return 0 if total_count.to_i.zero?

    ((processed_count.to_f / total_count) * 100).clamp(0, 100).round
  end

  def matches_found = linked_count.to_i + suggested_count.to_i
end
