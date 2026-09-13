require "test_helper"

class AccountStatements::PaperlessImportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    @connection = paperless_connections(:one)
    sign_in @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "new renders the search modal with stubbed results" do
    Provider::Paperless.any_instance.expects(:search_documents).returns(
      "results" => [ { "id" => 501, "title" => "March Statement", "created" => "2026-07-01", "correspondent" => 7 } ],
      "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns(7 => "Chase Bank")

    get new_account_statements_paperless_import_path

    assert_response :success
    assert_select "turbo-frame#paperless_statement_search_results"
    assert_select "p", text: "March Statement"
  end

  test "new seeds the search query from the account's institution name" do
    @account.update!(institution_name: "Chase Bank")
    Provider::Paperless.any_instance.expects(:search_documents).with(has_entries(query: "Chase Bank")).returns(
      "results" => [], "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns({})

    get new_account_statements_paperless_import_path(account_id: @account.id)

    assert_response :success
  end

  test "new marks an already-imported document and hides the import button for it" do
    statement = AccountStatement.create_from_upload!(
      family: @connection.family,
      account: nil,
      file: uploaded_file(filename: "existing.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(source: "paperless_import", paperless_connection: @connection, paperless_document_id: 501)

    Provider::Paperless.any_instance.expects(:search_documents).returns(
      "results" => [ { "id" => 501, "title" => "March Statement", "created" => "2026-07-01", "correspondent" => nil } ],
      "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns({})

    get new_account_statements_paperless_import_path

    assert_response :success
    assert_select "a[href='#{account_statement_path(statement)}']", text: I18n.t("account_statements.paperless_imports.search_result.view_statement")
    assert_select "button", text: I18n.t("account_statements.paperless_imports.search_result.import"), count: 0
  end

  test "new marks an unsupported document type without an import button" do
    Provider::Paperless.any_instance.expects(:search_documents).returns(
      "results" => [ { "id" => 502, "title" => "Photo", "created" => "2026-07-01", "correspondent" => nil, "mime_type" => "image/png" } ],
      "next" => nil
    )
    Provider::Paperless.any_instance.expects(:correspondents).returns({})

    get new_account_statements_paperless_import_path

    assert_response :success
    assert_includes response.body, I18n.t("account_statements.paperless_imports.search_result.unsupported")
    assert_select "button", text: I18n.t("account_statements.paperless_imports.search_result.import"), count: 0
  end

  test "new renders a localized error state when Paperless is unreachable" do
    Provider::Paperless.any_instance.expects(:search_documents).raises(Provider::Paperless::Error.new("down", :unreachable))

    get new_account_statements_paperless_import_path

    assert_response :success
    assert_select "p", text: I18n.t("account_statements.paperless_imports.provider_errors.unreachable")
  end

  test "new 404s when the family has no configured connection" do
    @connection.destroy

    get new_account_statements_paperless_import_path

    assert_response :not_found
  end

  test "non manager is redirected away from the search modal" do
    sign_in family_guest

    get new_account_statements_paperless_import_path

    assert_redirected_to accounts_url
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "read only shared user cannot search scoped to an account they cannot manage" do
    sign_in users(:family_member)
    account = accounts(:credit_card)

    get new_account_statements_paperless_import_path(account_id: account.id)

    assert_redirected_to account_url(account, tab: "statements")
  end

  test "create imports into the unmatched inbox from the vault" do
    Provider::Paperless.any_instance.expects(:document).with(501).returns(
      "id" => 501, "title" => "March Statement", "correspondent" => nil, "mime_type" => "application/pdf", "original_file_name" => nil
    )
    Provider::Paperless.any_instance.expects(:file).with(501, kind: :download).returns([ "%PDF-1.4 statement content", "application/pdf" ])

    assert_difference "AccountStatement.count", 1 do
      assert_no_enqueued_jobs do
        post account_statements_paperless_imports_path(document_id: 501)
      end
    end

    statement = AccountStatement.order(:created_at).last
    assert_nil statement.account
    assert statement.unmatched?
    assert statement.paperless_import?
    assert_equal 501, statement.paperless_document_id
    assert_select "turbo-stream[action=redirect]"
  end

  test "create imports into the given account" do
    Provider::Paperless.any_instance.expects(:document).with(502).returns(
      "id" => 502, "title" => "March Statement", "correspondent" => nil, "mime_type" => "application/pdf", "original_file_name" => nil
    )
    Provider::Paperless.any_instance.expects(:file).with(502, kind: :download).returns([ "%PDF-1.4 statement content", "application/pdf" ])

    assert_difference "AccountStatement.count", 1 do
      post account_statements_paperless_imports_path(document_id: 502, account_id: @account.id)
    end

    statement = AccountStatement.order(:created_at).last
    assert_equal @account, statement.account
    assert statement.linked?
    assert_select "turbo-stream[action=redirect]"
  end

  test "create refuses to import a document already imported" do
    statement = AccountStatement.create_from_upload!(
      family: @connection.family,
      account: nil,
      file: uploaded_file(filename: "existing.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    statement.update!(source: "paperless_import", paperless_connection: @connection, paperless_document_id: 503)

    assert_no_difference "AccountStatement.count" do
      post account_statements_paperless_imports_path(document_id: 503)
    end

    assert_response :unprocessable_entity
    assert_select "turbo-stream[action=append][target=notification-tray]"
  end

  test "create rejects an unsupported document with a localized message" do
    Provider::Paperless.any_instance.expects(:document).with(504).returns(
      "id" => 504, "title" => "Photo", "correspondent" => nil, "mime_type" => "image/png", "original_file_name" => nil
    )
    Provider::Paperless.any_instance.expects(:file).with(504, kind: :download).returns([ "\x89PNG\r\n\x1a\n".b, "image/png" ])

    assert_no_difference "AccountStatement.count" do
      post account_statements_paperless_imports_path(document_id: 504)
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("account_statements.paperless_imports.create.errors.invalid.unsupported_type")
  end

  test "create maps a provider error to a 422 and logs it" do
    Provider::Paperless.any_instance.expects(:document).with(505).raises(Provider::Paperless::Error.new("bad token", :unauthorized))

    assert_difference "DebugLogEntry.count", 1 do
      post account_statements_paperless_imports_path(document_id: 505)
    end

    assert_response :unprocessable_entity
    assert_includes response.body, I18n.t("account_statements.paperless_imports.provider_errors.unauthorized")
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "paperless", entry.provider_key
    assert_equal "provider_sync", entry.category
  end

  test "create with a cross-family account id 404s" do
    other_account = Account.create!(
      family: families(:empty),
      owner: users(:empty),
      name: "Other family account",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )

    post account_statements_paperless_imports_path(document_id: 506, account_id: other_account.id)

    assert_response :not_found
  end

  test "create never enqueues a background job" do
    Provider::Paperless.any_instance.expects(:document).with(507).returns(
      "id" => 507, "title" => "March Statement", "correspondent" => nil, "mime_type" => "application/pdf", "original_file_name" => nil
    )
    Provider::Paperless.any_instance.expects(:file).with(507, kind: :download).returns([ "%PDF-1.4 statement content", "application/pdf" ])

    assert_no_enqueued_jobs do
      post account_statements_paperless_imports_path(document_id: 507)
    end
  end
end
