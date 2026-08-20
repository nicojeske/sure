# frozen_string_literal: true

# Shared loading for the /receipts list: the family's connection, the whitelisted filters, and the
# paginated scope. Included by both ReceiptsController (renders the page) and
# Receipts::LinksController (re-renders the list after a confirm/dismiss/unlink), so a mutation
# always re-queries through exactly the same filters the user is looking at.
module ReceiptLinkListing
  extend ActiveSupport::Concern

  STATUSES = %w[linked suggested dismissed all].freeze
  SOURCES = %w[all auto manual].freeze
  PER_PAGE = 25

  private
    def set_paperless_connection
      connection = Current.family.paperless_connection
      @paperless_connection = connection&.configured? ? connection : nil
    end

    def set_list_filters
      @status = STATUSES.include?(params[:status]) ? params[:status] : "linked"
      @source = SOURCES.include?(params[:source]) ? params[:source] : "all"
    end

    def load_receipt_link_list
      set_list_filters
      return if @paperless_connection.nil?

      @pagy, @receipt_links = pagy(receipt_links_scope, limit: PER_PAGE)
    end

    # Scoped by paperless_connection_id rather than a join up to families: there is exactly one
    # connection per family (unique index), so this *is* the family filter, and it hits
    # index_receipt_links_on_paperless_connection_id_and_created_at directly. The join to accounts
    # exists only to apply the per-user account permission filter.
    def accessible_receipt_links
      ReceiptLink
        .where(paperless_connection: @paperless_connection)
        .joins(transaction_record: { entry: :account })
        .merge(Account.accessible_by(Current.user))
    end

    def receipt_links_scope
      scope = accessible_receipt_links
        .preload(:paperless_connection, transaction_record: { entry: :account })
        .order(created_at: :desc)

      scope = scope.where(status: @status) unless @status == "all"
      scope = scope.where(source: @source) unless @source == "all"
      scope
    end

    # Carried on every action link so a mutation re-renders the list the user is actually looking
    # at, rather than snapping them back to the unfiltered first page.
    def list_filter_params
      { status: @status, source: @source, page: params[:page].presence }.compact
    end
end
