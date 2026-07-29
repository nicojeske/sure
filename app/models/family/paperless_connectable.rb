# frozen_string_literal: true

module Family::PaperlessConnectable
  extend ActiveSupport::Concern

  included do
    has_one :paperless_connection, dependent: :destroy
  end

  def paperless_configured?
    paperless_connection&.configured? || false
  end
end
