# frozen_string_literal: true

# Progress reporting shared by PaperlessScanFamilyJob (transaction-first) and
# PaperlessSweepDocumentsJob (document-first) — both drive the same PaperlessScan row and the same
# `receipts/scan_status` partial, so how a run finishes and how it's broadcast can't drift between
# the two directions.
module PaperlessScanReporting
  extend ActiveSupport::Concern

  private
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

    def log_scan_error(scan, error, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless scan failed: #{error.message}",
        source: self.class.name,
        provider_key: "paperless",
        family: scan.family,
        metadata: metadata.merge(error_type: error.error_type, paperless_scan_id: scan.id)
      )
    end
end
