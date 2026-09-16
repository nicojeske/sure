# frozen_string_literal: true

# Kicks off a manual family-wide Paperless scan from /receipts. Not admin-gated: per-transaction
# scanning is already available to any member (TransactionsController#match_receipt), and the
# progress partial is broadcast to the whole family stream so it cannot vary by viewer.
class Receipts::ScansController < ApplicationController
  MODES = %w[transactions documents].freeze
  JOB_FOR_MODE = {
    "transactions" => PaperlessScanFamilyJob,
    "documents" => PaperlessSweepDocumentsJob
  }.freeze

  def create
    connection = Current.family.paperless_connection

    unless connection&.configured?
      return redirect_to receipts_path, alert: t("receipts.scans.create.not_configured")
    end

    sweep_stale_scans(connection)

    # Checked before inserting for the same reason as PaperlessScanAllJob: show the run that's
    # already going rather than relying on a failed INSERT. The rescue below covers real races.
    if (existing = connection.paperless_scans.in_progress.recent.first)
      @scan = existing
      return render_scan_status
    end

    mode = MODES.include?(params[:mode]) ? params[:mode] : "transactions"

    @scan = PaperlessScan.create!(
      family_id: Current.family.id,
      paperless_connection: connection,
      trigger: "manual",
      mode: mode
    )
    JOB_FOR_MODE.fetch(mode).perform_later(@scan.id)

    render_scan_status
  rescue ActiveRecord::RecordNotUnique
    # The partial unique index caught a double-click or a race with the nightly job. Show the run
    # that's already going rather than an error — it's what the user wanted anyway.
    @scan = connection.paperless_scans.in_progress.recent.first || connection.latest_scan
    render_scan_status
  end

  private
    # A worker that died mid-run leaves a `running` row that would otherwise block every future
    # scan via the partial unique index.
    def sweep_stale_scans(connection)
      connection.paperless_scans.in_progress.each do |scan|
        next unless scan.stale?

        scan.update!(
          status: "failed",
          error: t("receipts.scans.create.timed_out"),
          completed_at: Time.current
        )
      end
    end

    def render_scan_status
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to receipts_path }
      end
    end
end
