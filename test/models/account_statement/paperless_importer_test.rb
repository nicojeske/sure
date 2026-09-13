require "test_helper"

class AccountStatement::PaperlessImporterTest < ActiveSupport::TestCase
  setup do
    @connection = paperless_connections(:one)
    @account = accounts(:depository)
    @importer = AccountStatement::PaperlessImporter.new(@connection)
  end

  test "imports a document into the given account" do
    stub_document(501, title: "Kontoauszug Januar", correspondent: 9, mime_type: "application/pdf")
    stub_download(501, "%PDF-1.4 statement content", "application/pdf")
    stub_correspondents({ 9 => "Chase Bank" })

    statement = @importer.import!(document_id: "501", account: @account)

    assert_equal @account, statement.account
    assert statement.linked?
    assert statement.paperless_import?
    assert_equal @connection, statement.paperless_connection
    assert_equal 501, statement.paperless_document_id
    assert_equal "Kontoauszug Januar.pdf", statement.filename
    assert_equal "Chase Bank", statement.institution_name_hint
    assert statement.original_file.attached?
  end

  test "imports into the unmatched inbox and runs account matching without an account" do
    @account.update!(institution_name: "Chase Bank 6789")
    stub_document(502, title: "Chase Bank 2024-01", correspondent: nil, mime_type: "application/pdf")
    stub_download(502, "%PDF-1.4 statement content", "application/pdf")

    statement = @importer.import!(document_id: 502, account: nil)

    assert_nil statement.account
    assert statement.unmatched?
    assert_equal @account, statement.suggested_account
  end

  test "imports a csv document" do
    stub_document(503, title: "Statement", correspondent: nil, mime_type: "text/csv")
    stub_download(503, "date,amount\n2024-01-01,1\n", "text/csv")

    statement = @importer.import!(document_id: 503, account: @account)

    assert statement.csv?
  end

  test "uses the original filename when its extension already matches the sniffed type" do
    stub_document(504, title: "Some Title", original_file_name: "Kontoauszug_2024_01.pdf", correspondent: nil, mime_type: "application/pdf")
    stub_download(504, "%PDF-1.4 statement content", "application/pdf")

    statement = @importer.import!(document_id: 504, account: @account)

    assert_equal "Kontoauszug_2024_01.pdf", statement.filename
  end

  test "falls back to a generic filename when there is no usable title or original filename" do
    stub_document(505, title: nil, correspondent: nil, mime_type: "application/pdf")
    stub_download(505, "%PDF-1.4 statement content", "application/pdf")

    statement = @importer.import!(document_id: 505, account: @account)

    assert_equal "paperless-document-505.pdf", statement.filename
  end

  test "sniffs the downloaded bytes rather than trusting a mismatched declared mime type" do
    # Paperless's /download/ can return an archived PDF even when the original document's own
    # mime_type (and content-type header) still says something else.
    stub_document(506, title: "Archived Statement", correspondent: nil, mime_type: "image/png", archived_file_name: "archive.pdf")
    stub_download(506, "%PDF-1.4 statement content", "image/png")

    statement = @importer.import!(document_id: 506, account: @account)

    assert statement.pdf?
  end

  test "rejects an unsupported document type" do
    stub_document(507, title: "Photo", correspondent: nil, mime_type: "image/png")
    stub_download(507, "\x89PNG\r\n\x1a\n".b, "image/png")

    assert_no_difference [ "AccountStatement.count", "ActiveStorage::Blob.count" ] do
      error = assert_raises(AccountStatement::InvalidUploadError) do
        @importer.import!(document_id: 507, account: @account)
      end

      assert_equal :unsupported_type, error.reason
    end
  end

  test "rejects a document larger than the statement size limit" do
    stub_document(508, title: "Big Statement", correspondent: nil, mime_type: "application/pdf")
    stub_download(508, "%PDF-1.4 " + ("x" * AccountStatement::MAX_FILE_SIZE), "application/pdf")

    assert_no_difference [ "AccountStatement.count", "ActiveStorage::Blob.count" ] do
      error = assert_raises(AccountStatement::InvalidUploadError) do
        @importer.import!(document_id: 508, account: @account)
      end

      assert_equal :too_large, error.reason
    end
  end

  test "refuses to import a document already imported for the same connection" do
    existing = AccountStatement.create_from_upload!(
      family: @connection.family,
      account: @account,
      file: uploaded_file(filename: "existing.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    existing.update!(source: "paperless_import", paperless_connection: @connection, paperless_document_id: 509)

    document_stub = stub_document(509, title: "Whatever", correspondent: nil, mime_type: "text/csv")
    download_stub = stub_download(509, "date,amount\n2024-01-01,1\n", "text/csv")

    error = assert_raises(AccountStatement::PaperlessImporter::AlreadyImportedError) do
      @importer.import!(document_id: 509, account: @account)
    end

    assert_equal existing, error.statement
    assert_not_requested document_stub
    assert_not_requested download_stub
  end

  test "raises a duplicate error for identical bytes already in the vault under a different document" do
    existing = AccountStatement.create_from_upload!(
      family: @connection.family,
      account: @account,
      file: uploaded_file(filename: "existing.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n")
    )
    stub_document(510, title: "Duplicate", correspondent: nil, mime_type: "text/csv")
    stub_download(510, "date,amount\n2024-01-01,1\n", "text/csv")

    error = assert_raises(AccountStatement::DuplicateUploadError) do
      @importer.import!(document_id: 510, account: @account)
    end

    assert_equal existing, error.statement
  end

  test "propagates a paperless provider error" do
    stub_request(:get, "https://paperless.example.com/api/documents/511/")
      .to_return(status: 401, body: { "detail" => "Invalid token" }.to_json)

    error = assert_raises(Provider::Paperless::Error) do
      @importer.import!(document_id: 511, account: @account)
    end

    assert_equal :unauthorized, error.error_type
  end

  test "rejects an unparseable document id" do
    error = assert_raises(AccountStatement::InvalidUploadError) do
      @importer.import!(document_id: "not-a-number", account: @account)
    end

    assert_equal :unknown_document, error.reason
  end

  test "importable_document? is permissive when mime type is missing or an archive exists" do
    assert AccountStatement::PaperlessImporter.importable_document?({ "mime_type" => "application/pdf" })
    assert AccountStatement::PaperlessImporter.importable_document?({ "mime_type" => "text/csv" })
    assert_not AccountStatement::PaperlessImporter.importable_document?({ "mime_type" => "image/png" })
    assert AccountStatement::PaperlessImporter.importable_document?({ "mime_type" => "image/png", "archived_file_name" => "archive.pdf" })
    assert AccountStatement::PaperlessImporter.importable_document?({})
  end

  private
    def stub_document(id, title:, correspondent:, mime_type:, original_file_name: nil, archived_file_name: nil)
      stub_request(:get, "https://paperless.example.com/api/documents/#{id}/")
        .to_return(
          status: 200,
          body: {
            "id" => id,
            "title" => title,
            "correspondent" => correspondent,
            "mime_type" => mime_type,
            "original_file_name" => original_file_name,
            "archived_file_name" => archived_file_name
          }.to_json
        )
    end

    def stub_download(id, bytes, content_type)
      stub_request(:get, "https://paperless.example.com/api/documents/#{id}/download/")
        .to_return(status: 200, body: bytes.b, headers: { "Content-Type" => content_type })
    end

    def stub_correspondents(correspondents)
      results = correspondents.map { |id, name| { "id" => id, "name" => name } }

      stub_request(:get, "https://paperless.example.com/api/correspondents/")
        .with(query: { "page_size" => "100" })
        .to_return(status: 200, body: { "next" => nil, "results" => results }.to_json)
    end
end
