# frozen_string_literal: true

# Family-wide view of what Paperless receipt matching has produced. Visible to every family
# member; configuring the connection stays admin-only over in Settings::ReceiptsController.
class ReceiptsController < ApplicationController
  include ReceiptLinkListing
  include UnmatchedDocumentsListing

  before_action :set_paperless_connection

  def index
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.receipts"), nil ]
    ]

    @scan = @paperless_connection&.latest_scan
    set_list_filters

    # "unmatched" lists Paperless documents with no linked ReceiptLink at all, not a filtered
    # ReceiptLink query — a completely different data source from every other status value.
    if @status == "unmatched"
      load_unmatched_documents
    else
      load_receipt_link_list
    end
  end
end
