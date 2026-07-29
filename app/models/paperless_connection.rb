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

  def configured?
    base_url.present? && api_token.present?
  end

  def document_url(document_id)
    "#{base_url}/documents/#{document_id}/details"
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
