# Faraday client for the Paperless-ngx REST API (per-family base_url/token, hence Faraday
# over the HTTParty providers' class-level base_uri — see docs/api.md for endpoint shapes).
class Provider::Paperless
  extend SslConfigurable

  class Error < Provider::Error
    attr_reader :error_type

    def initialize(message, error_type = :unknown, details: nil)
      super(message, details: details)
      @error_type = error_type
    end
  end

  API_VERSION_HEADER = "application/json; version=10"
  DEFAULT_PAGE_SIZE = 25
  CORRESPONDENTS_PAGE_SIZE = 100

  def initialize(base_url:, api_token:, verify_ssl: true)
    @base_url = base_url.to_s.chomp("/")
    @api_token = api_token
    @verify_ssl = verify_ssl
  end

  # GET /api/documents/?page_size=1 - validates the connection, returns the total document count.
  def test_connection
    get("/api/documents/", page_size: 1)["count"].to_i
  end

  # `query:` is sent as `content__icontains`, not Paperless's own `query=` full-text search.
  # `query=` depends on the instance's Whoosh search index being built/enabled, which is
  # inconsistent across self-hosted setups (confirmed on a real instance where `query=` returned
  # zero hits for a term that plainly appears in `content`) — `content__icontains` is a plain
  # substring filter against the already-OCR'd body and has no such dependency.
  def search_documents(query: nil, created_from: nil, created_to: nil, page: 1, page_size: DEFAULT_PAGE_SIZE, ordering: "-created")
    get(
      "/api/documents/",
      page: page,
      page_size: page_size,
      ordering: ordering,
      content__icontains: query,
      created__date__gte: created_from&.to_s,
      created__date__lte: created_to&.to_s
    )
  end

  def document(id)
    get("/api/documents/#{id}/")
  end

  # { id => name }, cached — resolves correspondent ids returned on documents/search results.
  def correspondents
    Rails.cache.fetch([ "paperless/correspondents", Digest::SHA256.hexdigest(base_url) ], expires_in: 1.hour) do
      fetch_all_correspondents
    end
  end

  # Returns [bytes, content_type]. Never routed through the JSON parser below.
  def file(id, kind: :thumb)
    response = connection.get(file_path(id, kind)) { |req| req.headers["Accept"] = "*/*" }
    handle_status!(response)
    [ response.body, response.headers["content-type"] ]
  rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
    raise Error.new("Could not reach Paperless: #{e.message}", :unreachable)
  end

  private
    attr_reader :base_url, :api_token, :verify_ssl

    def file_path(id, kind)
      case kind
      when :thumb then "/api/documents/#{id}/thumb/"
      when :preview then "/api/documents/#{id}/preview/"
      when :download then "/api/documents/#{id}/download/"
      else raise ArgumentError, "unknown file kind: #{kind.inspect}"
      end
    end

    def fetch_all_correspondents
      results = {}
      path = "/api/correspondents/"
      params = { page_size: CORRESPONDENTS_PAGE_SIZE }

      loop do
        payload = get(path, params)
        Array(payload["results"]).each { |c| results[c["id"]] = c["name"] }

        next_url = payload["next"]
        break if next_url.blank?

        path = relative_path_for(next_url)
        params = {}
      end

      results
    end

    # Paperless's `next` links are absolute; re-derive a same-host relative path rather than
    # requesting the absolute URL directly, so the token can never be sent to another host.
    # Only the host is checked (not scheme): a self-hosted instance behind a reverse proxy
    # routinely reports `http://` in its own generated links even though it's only reachable
    # over `https://` externally — the scheme is irrelevant anyway since we re-issue the
    # request through our own connection, which is already pinned to the configured scheme.
    def relative_path_for(next_url)
      uri = URI.parse(next_url)
      configured = URI.parse(base_url)

      unless uri.host == configured.host
        raise Error.new("Refusing to follow Paperless link to untrusted host: #{uri.host.inspect}", :untrusted_host)
      end

      uri.request_uri
    end

    def get(path, params = {})
      response = connection.get(path, params.compact)
      handle_status!(response)
      JSON.parse(response.body)
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError => e
      raise Error.new("Could not reach Paperless: #{e.message}", :unreachable)
    rescue JSON::ParserError => e
      raise Error.new("Could not parse Paperless response: #{e.message}", :parse_error)
    end

    def handle_status!(response)
      case response.status
      when 200..299
        response
      when 401, 403
        raise Error.new("Paperless rejected the API token", :unauthorized)
      when 404
        raise Error.new("Paperless resource not found", :not_found)
      when 429
        raise Error.new("Paperless rate limit exceeded", :rate_limited)
      when 500..599
        raise Error.new("Paperless server error (status #{response.status})", :server_error)
      else
        raise Error.new("Unexpected Paperless response (status #{response.status})", :unknown)
      end
    end

    def connection
      @connection ||= Faraday.new(url: base_url, ssl: ssl_options) do |faraday|
        faraday.request :retry, max: 2
        faraday.options.open_timeout = 10
        faraday.options.timeout = 20
        faraday.headers["Authorization"] = "Token #{api_token}"
        faraday.headers["Accept"] = API_VERSION_HEADER
      end
    end

    def ssl_options
      options = self.class.faraday_ssl_options.dup
      options[:verify] = false unless verify_ssl
      options
    end
end
