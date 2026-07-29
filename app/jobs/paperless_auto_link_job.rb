# frozen_string_literal: true

class PaperlessAutoLinkJob < ApplicationJob
  include ActionView::RecordIdentifier

  queue_as :low_priority

  def perform(transaction_id)
    transaction = Transaction.find_by(id: transaction_id)
    return unless transaction

    entry = transaction.entry
    return unless entry

    connection = entry.account.family.paperless_connection
    return unless connection&.configured?

    begin
      PaperlessConnection::Matcher.new(connection).match!(transaction)
    rescue Provider::Paperless::Error => e
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless auto-link failed: #{e.message}",
        source: "PaperlessAutoLinkJob",
        provider_key: "paperless",
        family: connection.family,
        metadata: { error_type: e.error_type, transaction_id: transaction.id }
      )
    end

    broadcast_receipt_links(transaction, entry)
  end

  private
    def broadcast_receipt_links(transaction, entry)
      html = ApplicationController.render(
        partial: "receipt_links/index",
        assigns: { entry: entry, receipt_links: transaction.receipt_links.ordered }
      )

      Turbo::StreamsChannel.broadcast_replace_to(
        entry.account.family,
        target: dom_id(transaction, :receipt_links),
        html: html
      )
    end
end
