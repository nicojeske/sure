# frozen_string_literal: true

class PaperlessConnection < ApplicationRecord
  include Encryptable

  if encryption_ready?
    encrypts :api_token
  end

  belongs_to :family
  has_many :receipt_links, dependent: :destroy

  validates :base_url, presence: true
  validate :base_url_must_be_valid_http_url

  before_validation :normalize_base_url

  # Name heuristics used only to pre-select the settings mapping dropdowns — the user's actual
  # choice always wins once saved. Order matters: net/tax are checked before total so a field
  # like "Netto-Betrag" isn't grabbed by the broader "betrag" alternative meant for the total.
  FIELD_NAME_HINTS = {
    net_amount_field_id: /netto|\bnet\b/i,
    tax_amount_field_id: /mwst|ust\b|vat|tax|steuer/i,
    total_amount_field_id: /total|gross|brutto|betrag|summe|amount/i,
    reference_field_id: /rechnungsnummer|invoice|reference|beleg|number|nummer/i
  }.freeze

  def configured?
    base_url.present? && api_token.present?
  end

  def document_url(document_id)
    "#{base_url}/documents/#{document_id}/details"
  end

  # Best-guess field id for a mapping role, used only to pre-fill an unset settings dropdown.
  # `custom_fields` is `Provider::Paperless#custom_fields`'s { id => { "name" =>, "data_type" => } }.
  def suggested_field_id(role, custom_fields, taken_ids: [])
    hint = FIELD_NAME_HINTS.fetch(role)
    data_types = role == :reference_field_id ? %w[string url integer select] : %w[monetary]

    custom_fields
      .reject { |id, _| taken_ids.include?(id) }
      .select { |_, meta| data_types.include?(meta["data_type"]) }
      .find { |_, meta| meta["name"].to_s.match?(hint) }
      &.first
  end

  private
    def normalize_base_url
      self.base_url = base_url.to_s.strip.sub(%r{/+\z}, "") if base_url.present?
    end

    def base_url_must_be_valid_http_url
      return if base_url.blank?

      uri = URI.parse(base_url)
      unless uri.is_a?(URI::HTTP) && uri.host.present?
        errors.add(:base_url, :invalid)
      end
    rescue URI::InvalidURIError
      errors.add(:base_url, :invalid)
    end
end
