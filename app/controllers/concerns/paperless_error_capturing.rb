# Logs a failed Paperless request where support can see it (DebugLogEntry),
# for the controllers that call Paperless directly.
module PaperlessErrorCapturing
  extend ActiveSupport::Concern

  private
    def capture_paperless_error(error, source:, message: "Paperless request failed", level: "error", account: nil, **metadata)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: level,
        message: "#{message}: #{error.message}",
        source: source,
        provider_key: "paperless",
        family: Current.family,
        account: account,
        metadata: { error_type: error.error_type, **metadata }
      )
    end
end
