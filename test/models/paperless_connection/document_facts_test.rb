require "test_helper"

class PaperlessConnection::DocumentFactsTest < ActiveSupport::TestCase
  setup do
    @connection = paperless_connections(:one)
    @connection.update!(
      total_amount_field_id: 2,
      net_amount_field_id: 3,
      tax_amount_field_id: 4,
      reference_field_id: 5
    )

    @field_metadata = {
      2 => { "name" => "Betrag", "data_type" => "monetary", "currency" => "EUR" },
      3 => { "name" => "Netto-Betrag", "data_type" => "monetary", "currency" => "EUR" },
      4 => { "name" => "MwSt-Betrag", "data_type" => "monetary", "currency" => "EUR" },
      5 => { "name" => "Rechnungsnummer", "data_type" => "string", "currency" => nil }
    }

    @facts = PaperlessConnection::DocumentFacts.new(@connection, @field_metadata)
  end

  test "parses currency-prefixed monetary values and the reference" do
    document = {
      "custom_fields" => [
        { "field" => 2, "value" => "EUR23.42" },
        { "field" => 3, "value" => "EUR21.39" },
        { "field" => 4, "value" => "EUR2.03" },
        { "field" => 5, "value" => "100387210386" }
      ]
    }

    facts = @facts.for(document)

    assert_equal Money.new(23.42, "EUR"), facts.total
    assert_equal Money.new(21.39, "EUR"), facts.net
    assert_equal Money.new(2.03, "EUR"), facts.tax
    assert_equal "100387210386", facts.reference
  end

  test "parses a bare monetary value with no currency prefix using the field's default currency" do
    document = { "custom_fields" => [ { "field" => 2, "value" => "23.42" } ] }

    facts = @facts.for(document)

    assert_equal Money.new(23.42, "EUR"), facts.total
  end

  test "returns nil for an unmapped role" do
    @connection.update!(net_amount_field_id: nil)
    document = { "custom_fields" => [ { "field" => 3, "value" => "EUR21.39" } ] }

    facts = @facts.for(document)

    assert_nil facts.net
  end

  test "returns nil for a garbage monetary value instead of raising" do
    document = { "custom_fields" => [ { "field" => 2, "value" => "not a number" } ] }

    facts = @facts.for(document)

    assert_nil facts.total
  end

  test "returns nil for an unknown currency code instead of raising" do
    document = { "custom_fields" => [ { "field" => 2, "value" => "XXX23.42" } ] }

    facts = @facts.for(document)

    assert_nil facts.total
  end

  test "returns all-nil facts for a document with no custom_fields key" do
    facts = @facts.for({})

    assert_nil facts.total
    assert_nil facts.net
    assert_nil facts.tax
    assert_nil facts.reference
  end
end
