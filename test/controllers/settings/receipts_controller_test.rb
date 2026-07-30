require "test_helper"

class Settings::ReceiptsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @connection = paperless_connections(:one)
    sign_in users(:family_admin)

    Provider::Paperless.any_instance.stubs(:custom_fields).returns(
      2 => { "name" => "Betrag", "data_type" => "monetary", "currency" => "EUR" },
      3 => { "name" => "Netto-Betrag", "data_type" => "monetary", "currency" => "EUR" },
      5 => { "name" => "Rechnungsnummer", "data_type" => "string", "currency" => nil }
    )
  end

  test "non-admin is redirected" do
    sign_in users(:family_member)

    get settings_receipts_path
    assert_redirected_to root_path
  end

  test "shows the settings page" do
    get settings_receipts_path
    assert_response :success
  end

  test "custom field mapping selects auto-submit on change" do
    get settings_receipts_path

    assert_response :success
    # Regression: these selects previously rendered with no data-auto-submit-form-target
    # attribute at all, so choosing a mapping in the browser silently submitted nothing —
    # StyledFormBuilder#select only applies data/html attributes passed as the 4th
    # (html_options) positional argument, not the 3rd (select-options) one.
    %w[total_amount_field_id net_amount_field_id tax_amount_field_id reference_field_id].each do |field|
      assert_select "select[name='paperless_connection[#{field}]'][data-auto-submit-form-target='auto']"
    end
  end

  test "creates a connection when none exists" do
    @connection.destroy

    patch settings_receipts_path, params: { paperless_connection: {
      base_url: "https://paperless.new-instance.com",
      api_token: "brand-new-token"
    } }

    assert_redirected_to settings_receipts_path
    connection = families(:dylan_family).reload.paperless_connection
    assert_equal "https://paperless.new-instance.com", connection.base_url
    assert_equal "brand-new-token", connection.api_token
  end

  test "updates connection fields" do
    patch settings_receipts_path, params: { paperless_connection: {
      base_url: "https://paperless.updated.com",
      match_window_days: 5,
      min_auto_link_score: "0.75"
    } }

    assert_redirected_to settings_receipts_path
    @connection.reload
    assert_equal "https://paperless.updated.com", @connection.base_url
    assert_equal 5, @connection.match_window_days
    assert_equal 0.75, @connection.min_auto_link_score.to_f
  end

  test "updates the custom field mapping and structured match window" do
    patch settings_receipts_path, params: { paperless_connection: {
      base_url: @connection.base_url,
      total_amount_field_id: "2",
      net_amount_field_id: "3",
      reference_field_id: "5",
      structured_match_window_days: "14"
    } }

    assert_redirected_to settings_receipts_path
    @connection.reload
    assert_equal 2, @connection.total_amount_field_id
    assert_equal 3, @connection.net_amount_field_id
    assert_equal 5, @connection.reference_field_id
    assert_equal 14, @connection.structured_match_window_days
  end

  test "shows the settings page when fetching custom fields fails" do
    Provider::Paperless.any_instance.stubs(:custom_fields).raises(
      Provider::Paperless::Error.new("bad token", :unauthorized)
    )

    get settings_receipts_path

    assert_response :success
  end

  test "does not clobber the token when the masked placeholder is submitted" do
    patch settings_receipts_path, params: { paperless_connection: {
      base_url: @connection.base_url,
      api_token: "********"
    } }

    assert_equal "test-paperless-token", @connection.reload.api_token
  end

  test "clears the token when submitted blank" do
    patch settings_receipts_path, params: { paperless_connection: {
      base_url: @connection.base_url,
      api_token: ""
    } }

    assert_nil @connection.reload.api_token
  end

  test "renders errors when the connection is invalid" do
    patch settings_receipts_path, params: { paperless_connection: { base_url: "not-a-url" } }

    assert_response :unprocessable_entity
    assert_equal "https://paperless.example.com", @connection.reload.base_url
  end

  test "destroy removes the connection" do
    delete settings_receipts_path

    assert_redirected_to settings_receipts_path
    assert_nil families(:dylan_family).reload.paperless_connection
  end

  test "test_connection reports success" do
    Provider::Paperless.any_instance.stubs(:test_connection).returns(7)

    post test_connection_settings_receipts_path

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_match "7", body["message"]
    assert @connection.reload.last_connected_at.present?
  end

  test "test_connection reports a mapped error message on failure" do
    Provider::Paperless.any_instance.stubs(:test_connection).raises(
      Provider::Paperless::Error.new("bad token", :unauthorized)
    )

    post test_connection_settings_receipts_path

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["success"]
    assert_equal I18n.t("settings.receipts.test_connection.errors.unauthorized"), body["message"]
    assert @connection.reload.last_error.present?
  end

  test "test_connection refuses when not configured" do
    @connection.update_column(:api_token, nil)

    post test_connection_settings_receipts_path

    assert_response :success
    body = JSON.parse(response.body)
    assert_not body["success"]
  end
end
