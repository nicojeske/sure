require "test_helper"

class MerchantsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @merchant = merchants(:netflix)
  end

  test "lists the merchant's transactions from every account" do
    create_transaction(account: accounts(:depository), name: "Netflix checking", merchant: @merchant)
    create_transaction(account: accounts(:credit_card), name: "Netflix card", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Amazon order", merchant: merchants(:amazon))

    get merchant_url(@merchant)

    assert_response :success
    assert_match "Netflix checking", response.body
    assert_match "Netflix card", response.body
    assert_no_match "Amazon order", response.body
  end

  test "edit link returns to the merchant page it was opened from" do
    get merchant_url(@merchant, page: 2)

    assert_select "a[href=?]", edit_family_merchant_path(@merchant, return_to: merchant_path(@merchant, page: 2))
  end

  test "shows a provider merchant assigned to the family's transactions" do
    provider = ProviderMerchant.create!(name: "Coffee Co", source: "plaid")
    create_transaction(account: accounts(:depository), name: "Morning coffee", merchant: provider)

    get merchant_url(provider)

    assert_response :success
    assert_match "Morning coffee", response.body
  end

  test "leaves out transactions from accounts the user cannot access" do
    create_transaction(account: accounts(:investment), name: "Private Netflix", merchant: @merchant)
    create_transaction(account: accounts(:depository), name: "Shared Netflix", merchant: @merchant)

    sign_in users(:family_member)
    get merchant_url(@merchant)

    assert_response :success
    assert_match "Shared Netflix", response.body
    assert_no_match "Private Netflix", response.body
  end

  test "averages spending over purchases only" do
    create_transaction(account: accounts(:depository), name: "Netflix plan", merchant: @merchant, amount: 100)
    create_transaction(account: accounts(:depository), name: "Netflix refund", merchant: @merchant, amount: -100)

    get merchant_url(@merchant)

    assert_response :success
    assert_select "dt", text: "Average transaction" do |dt|
      assert_equal "$100.00", dt.first.next_element.text.strip
    end
  end

  test "does not show a provider merchant used only on accounts the user cannot access" do
    provider = ProviderMerchant.create!(name: "Private Co", source: "plaid")
    create_transaction(account: accounts(:investment), name: "Private purchase", merchant: provider)

    sign_in users(:family_member)
    get merchant_url(provider)

    assert_response :not_found
  end

  test "does not show another family's merchant" do
    other = families(:empty).merchants.create!(name: "Elsewhere")

    get merchant_url(other)

    assert_response :not_found
  end

  test "charts the merchant's spending as monthly bars over the last year" do
    create_transaction(account: accounts(:depository), name: "Netflix checking", merchant: @merchant)

    get merchant_url(@merchant)

    assert_select "turbo-frame#merchant_chart" do
      assert_select "[data-controller='bar-chart']"
      assert_select "a.segmented-control__segment--active[href=?]", merchant_path(@merchant, chart_view: "periodic", granularity: "month")
      assert_select "button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: Period.from_key("last_365_days").label_short)
    end
  end

  test "switches the chart to the running net flow" do
    create_transaction(account: accounts(:depository), name: "Netflix checking", merchant: @merchant)

    get merchant_url(@merchant, chart_view: "cumulative")

    assert_select "turbo-frame#merchant_chart [data-controller='time-series-chart']"
  end

  test "charts the chosen period without saving it as the user's default" do
    @user.update!(default_period: "last_30_days")

    get merchant_url(@merchant, period: "last_90_days")

    assert_select "turbo-frame#merchant_chart button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: Period.from_key("last_90_days").label_short)
    assert_equal "last_30_days", @user.reload.default_period
  end

  test "falls back to the last year for an unknown period" do
    get merchant_url(@merchant, period: "bogus")

    assert_response :success
    assert_select "turbo-frame#merchant_chart button[aria-label=?]", I18n.t("UI.period_picker.aria_label", period: Period.from_key("last_365_days").label_short)
  end
end
