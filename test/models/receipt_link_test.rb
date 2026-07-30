require "test_helper"

class ReceiptLinkTest < ActiveSupport::TestCase
  setup do
    @entry = entries(:transaction) # $10 USD
    @link = receipt_links(:linked_one)
  end

  test "amount_conflicts_with? is false when the document has no structured amount" do
    @link.document_amount = nil

    assert_not @link.amount_conflicts_with?(@entry)
  end

  test "amount_conflicts_with? is false when the document total matches the entry" do
    @link.document_amount = 10
    @link.document_currency = "USD"

    assert_not @link.amount_conflicts_with?(@entry)
  end

  test "amount_conflicts_with? is true when the document total differs from the entry" do
    @link.document_amount = 12.50
    @link.document_currency = "USD"

    assert @link.amount_conflicts_with?(@entry)
  end

  test "amount_conflicts_with? is true when the document currency differs from the entry" do
    @link.document_amount = 10
    @link.document_currency = "EUR"

    assert @link.amount_conflicts_with?(@entry)
  end

  test "amount_conflicts_with? is false when there is no entry" do
    @link.document_amount = 12.50
    @link.document_currency = "USD"

    assert_not @link.amount_conflicts_with?(nil)
  end
end
