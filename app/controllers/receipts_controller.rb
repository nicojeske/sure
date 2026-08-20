# frozen_string_literal: true

# Family-wide view of what Paperless receipt matching has produced. Visible to every family
# member; configuring the connection stays admin-only over in Settings::ReceiptsController.
class ReceiptsController < ApplicationController
  include ReceiptLinkListing

  before_action :set_paperless_connection

  def index
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.receipts"), nil ]
    ]

    @scan = @paperless_connection&.latest_scan
    load_receipt_link_list
  end
end
