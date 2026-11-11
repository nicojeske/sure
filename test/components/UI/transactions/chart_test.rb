require "test_helper"

class UI::Transactions::ChartTest < ViewComponent::TestCase
  setup do
    @search = Transaction::Search.new(families(:dylan_family))
    @period = Period.from_key("last_365_days")
  end

  test "links back to the transactions index by default" do
    render_inline(UI::Transactions::Chart.new(search: @search, period: @period))

    assert_selector "a.segmented-control__segment[href^='/transactions?']", count: 2
    assert_selector "a[href^='/transactions?'][href*='period=last_30_days']"
    assert_no_selector "turbo-frame"
  end

  test "links to the given url and keeps the page's state" do
    render_inline(UI::Transactions::Chart.new(search: @search, period: @period, url: "/merchants/1", view: "periodic", granularity: "week"))

    assert_selector "a.segmented-control__segment[href='/merchants/1?chart_view=cumulative&granularity=week']"
    assert_selector "a.segmented-control__segment[href='/merchants/1?chart_view=periodic&granularity=month']"
    assert_selector "a[href='/merchants/1?chart_view=periodic&granularity=week&period=last_30_days']"
    assert_no_selector "a[href^='/transactions']"
  end

  test "wraps itself in a frame whose links advance the address bar" do
    render_inline(UI::Transactions::Chart.new(search: @search, period: @period, url: "/merchants/1", frame: "merchant_chart"))

    assert_selector "turbo-frame#merchant_chart a.segmented-control__segment[data-turbo-action='advance']", count: 2
    assert_selector "turbo-frame#merchant_chart a[data-turbo-frame='merchant_chart'][href*='period=last_30_days']"
  end
end
