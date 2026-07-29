require "test_helper"

class Provider::PaperlessTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Paperless.new(base_url: "https://paperless.example.com", api_token: "test_token")
  end

  test "parses a documents list response and sends the auth + version headers" do
    stub = stub_request(:get, "https://paperless.example.com/api/documents/")
      .with(
        query: { "page" => "1", "page_size" => "25", "ordering" => "-created" },
        headers: {
          "Authorization" => "Token test_token",
          "Accept" => "application/json; version=10"
        }
      )
      .to_return(status: 200, body: documents_response_body)

    result = @provider.search_documents

    assert_equal 1, result["count"]
    assert_equal "Grocery Receipt", result["results"].first["title"]
    assert_requested stub
  end

  test "raises an unauthorized error on 401" do
    stub_request(:get, %r{https://paperless\.example\.com/api/documents/})
      .to_return(status: 401, body: { "detail" => "Invalid token" }.to_json)

    error = assert_raises(Provider::Paperless::Error) { @provider.search_documents }
    assert_equal :unauthorized, error.error_type
  end

  test "raises an unreachable error when the connection times out" do
    stub_request(:get, %r{https://paperless\.example\.com/api/documents/})
      .to_timeout

    error = assert_raises(Provider::Paperless::Error) { @provider.search_documents }
    assert_equal :unreachable, error.error_type
  end

  test "test_connection returns the total document count" do
    stub_request(:get, "https://paperless.example.com/api/documents/")
      .with(query: { "page_size" => "1" })
      .to_return(status: 200, body: { "count" => 42, "results" => [] }.to_json)

    assert_equal 42, @provider.test_connection
  end

  test "correspondents follows pagination and caches the result" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new

    page1 = stub_request(:get, "https://paperless.example.com/api/correspondents/")
      .with(query: { "page_size" => "100" })
      .to_return(
        status: 200,
        body: {
          "next" => "https://paperless.example.com/api/correspondents/?page=2&page_size=100",
          "results" => [ { "id" => 1, "name" => "Acme Corp" } ]
        }.to_json
      )

    page2 = stub_request(:get, "https://paperless.example.com/api/correspondents/")
      .with(query: { "page" => "2", "page_size" => "100" })
      .to_return(
        status: 200,
        body: { "next" => nil, "results" => [ { "id" => 2, "name" => "Widgets Inc" } ] }.to_json
      )

    result = @provider.correspondents

    assert_equal({ 1 => "Acme Corp", 2 => "Widgets Inc" }, result)
    assert_requested page1
    assert_requested page2

    @provider.correspondents

    assert_requested page1, times: 1
    assert_requested page2, times: 1
  ensure
    Rails.cache = original_cache
  end

  test "correspondents follows a next link whose scheme differs from the configured base_url" do
    # Real-world case: a self-hosted Paperless behind a reverse proxy often reports `http://`
    # in its own generated `next` links even though it's only reachable via `https://` externally.
    stub_request(:get, "https://paperless.example.com/api/correspondents/")
      .with(query: { "page_size" => "100" })
      .to_return(
        status: 200,
        body: {
          "next" => "http://paperless.example.com/api/correspondents/?page=2&page_size=100",
          "results" => [ { "id" => 1, "name" => "Acme Corp" } ]
        }.to_json
      )

    page2 = stub_request(:get, "https://paperless.example.com/api/correspondents/")
      .with(query: { "page" => "2", "page_size" => "100" })
      .to_return(status: 200, body: { "next" => nil, "results" => [] }.to_json)

    @provider.correspondents

    assert_requested page2
  end

  test "correspondents raises on a next link pointing at an untrusted host" do
    stub_request(:get, "https://paperless.example.com/api/correspondents/")
      .with(query: { "page_size" => "100" })
      .to_return(
        status: 200,
        body: {
          "next" => "https://evil.example.com/api/correspondents/?page=2&page_size=100",
          "results" => []
        }.to_json
      )

    error = assert_raises(Provider::Paperless::Error) { @provider.correspondents }
    assert_equal :untrusted_host, error.error_type
  end

  test "file returns raw bytes and the upstream content type without JSON parsing" do
    stub_request(:get, "https://paperless.example.com/api/documents/7/thumb/")
      .to_return(status: 200, body: "\xFF\xD8\xFF".b, headers: { "Content-Type" => "image/webp" })

    bytes, content_type = @provider.file(7, kind: :thumb)

    assert_equal "\xFF\xD8\xFF".b, bytes
    assert_equal "image/webp", content_type
  end

  private
    def documents_response_body
      {
        "count" => 1,
        "next" => nil,
        "results" => [
          { "id" => 1, "title" => "Grocery Receipt", "content" => "Total: 12.34", "created" => "2026-01-01T00:00:00Z" }
        ]
      }.to_json
    end
end
