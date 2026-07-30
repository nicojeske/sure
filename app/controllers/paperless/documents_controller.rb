# Proxies Paperless-ngx document bytes to the browser so the family's API token never leaves
# the server. Family-scoped only: any document reachable through the family's own Paperless
# connection is theirs to view (see Step 5 of the paperless plan for why no finer-grained
# per-document authorization exists).
class Paperless::DocumentsController < ApplicationController
  before_action :set_paperless_connection

  CACHE_EXPIRY = 1.hour

  # Renders the in-page preview modal (embeds `preview`/`thumbnail` as the source — no provider
  # HTTP call happens here). Opened via the eye button as `frame: :modal`.
  def show
    @document_id = params[:id]
    @receipt_link = receipt_link_for(@document_id)
  end

  def thumbnail
    serve(:thumb, disposition: :inline, cacheable: true)
  end

  def preview
    serve(:preview, disposition: :inline, cacheable: false)
  end

  def download
    serve(:download, disposition: :attachment, cacheable: false)
  end

  private
    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection

      head :not_found unless @paperless_connection&.configured?
    end

    def serve(kind, disposition:, cacheable:)
      bytes, content_type = cacheable ? fetch_cached(kind) : fetch(kind)

      send_data bytes, type: content_type, disposition: disposition, filename: filename_for(kind, content_type)
    rescue Provider::Paperless::Error => e
      handle_provider_error(e)
    end

    # Falls back to `send_data`'s own default (no filename:) when we don't have a cached title
    # or can't resolve an extension from the upstream content type.
    def filename_for(kind, content_type)
      return nil unless kind == :download

      title = receipt_link_for(params[:id])&.document_title
      extension = Mime::Type.lookup(content_type)&.symbol
      return nil if title.blank? || extension.blank?

      "#{title.parameterize}.#{extension}"
    end

    def receipt_link_for(document_id)
      @paperless_connection.receipt_links.where(document_id: document_id).order(created_at: :desc).first
    end

    def fetch_cached(kind)
      Rails.cache.fetch(cache_key(kind), expires_in: CACHE_EXPIRY) { fetch(kind) }
    end

    def fetch(kind)
      provider.file(params[:id], kind: kind)
    end

    def cache_key(kind)
      [ "paperless_document", @paperless_connection.id, kind, params[:id] ]
    end

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: @paperless_connection.base_url,
        api_token: @paperless_connection.api_token,
        verify_ssl: @paperless_connection.verify_ssl
      )
    end

    def handle_provider_error(error)
      case error.error_type
      when :not_found
        head :not_found
      when :unreachable
        head :bad_gateway
      else
        DebugLogEntry.capture(
          category: "provider_sync",
          level: "error",
          message: "Paperless document fetch failed: #{error.message}",
          source: self.class.name,
          provider_key: "paperless",
          family: Current.family,
          metadata: { error_type: error.error_type, document_id: params[:id] }
        )

        head :bad_gateway
      end
    end
end
