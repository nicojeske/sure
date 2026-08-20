# frozen_string_literal: true

# Family-wide view of what Paperless receipt matching has produced. Visible to every family
# member; configuring the connection stays admin-only over in Settings::ReceiptsController.
class ReceiptsController < ApplicationController
  STATUSES = %w[linked suggested dismissed all].freeze
  SOURCES = %w[all auto manual].freeze
  PER_PAGE = 25

  before_action :set_paperless_connection

  def index
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.receipts"), nil ]
    ]

    @status = STATUSES.include?(params[:status]) ? params[:status] : "linked"
    @source = SOURCES.include?(params[:source]) ? params[:source] : "all"
    @scan = @paperless_connection&.latest_scan

    return if @paperless_connection.nil?

    @pagy, @receipt_links = pagy(receipt_links_scope, limit: PER_PAGE)
  end

  private
    def set_paperless_connection
      connection = Current.family.paperless_connection
      @paperless_connection = connection&.configured? ? connection : nil
    end

    # Scoped by paperless_connection_id rather than a join up to families: there is exactly one
    # connection per family (unique index), so this *is* the family filter, and it hits
    # index_receipt_links_on_paperless_connection_id_and_created_at directly. The join to accounts
    # exists only to apply the per-user account permission filter.
    def receipt_links_scope
      scope = ReceiptLink
        .where(paperless_connection: @paperless_connection)
        .joins(transaction_record: { entry: :account })
        .merge(Account.accessible_by(Current.user))
        .preload(:paperless_connection, transaction_record: { entry: :account })
        .order(created_at: :desc)

      scope = scope.where(status: @status) unless @status == "all"
      scope = scope.where(source: @source) unless @source == "all"
      scope
    end
end
