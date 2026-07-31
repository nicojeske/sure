require "test_helper"

class UI::Transactions::DateFilterTest < ViewComponent::TestCase
  test "labels an exact calendar month" do
    render_inline(UI::Transactions::DateFilter.new(start_date: "2024-03-01", end_date: "2024-03-31"))

    assert_equal "March 2024", page.first("button").text.strip
  end

  test "labels an exact calendar year" do
    render_inline(UI::Transactions::DateFilter.new(start_date: "2024-01-01", end_date: "2024-12-31"))

    assert_equal "2024", page.first("button").text.strip
  end

  test "labels an arbitrary range as a custom range" do
    render_inline(UI::Transactions::DateFilter.new(start_date: "2024-03-05", end_date: "2024-03-20"))

    assert_equal "Custom range", page.first("button").text.strip
  end

  test "labels no filter as all time" do
    render_inline(UI::Transactions::DateFilter.new(start_date: nil, end_date: nil))

    assert_equal "All time", page.first("button").text.strip
  end
end
