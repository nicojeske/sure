# frozen_string_literal: true

# Turns a Paperless document's raw `custom_fields` array into typed facts, per the connection's
# field mapping. Never raises — an unmapped role or an unparseable value simply yields `nil` for
# that role, so callers fall back to the existing OCR-content matching path.
class PaperlessConnection::DocumentFacts
  Facts = Data.define(:total, :net, :tax, :reference)

  MONETARY_VALUE = /\A([A-Z]{3})?\s*(-?\d+(?:\.\d+)?)\z/

  def initialize(connection, field_metadata)
    @connection = connection
    @field_metadata = field_metadata
  end

  def for(document)
    values = Array(document["custom_fields"]).index_by { |cf| cf["field"] }.transform_values { |cf| cf["value"] }

    Facts.new(
      total: monetary_value(values[connection.total_amount_field_id], connection.total_amount_field_id),
      net: monetary_value(values[connection.net_amount_field_id], connection.net_amount_field_id),
      tax: monetary_value(values[connection.tax_amount_field_id], connection.tax_amount_field_id),
      reference: values[connection.reference_field_id].to_s.presence
    )
  end

  private
    attr_reader :connection, :field_metadata

    def monetary_value(raw_value, field_id)
      return nil if raw_value.blank? || field_id.nil?

      match = MONETARY_VALUE.match(raw_value.to_s.strip)
      return nil unless match

      currency = match[1] || field_metadata.dig(field_id, "currency") || connection.family&.currency
      Money.new(BigDecimal(match[2]), currency)
    rescue ArgumentError
      nil
    end
end
