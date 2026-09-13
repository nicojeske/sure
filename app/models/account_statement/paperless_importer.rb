# frozen_string_literal: true

# Downloads a single Paperless-ngx document and imports it into the Statement Vault, reusing
# AccountStatement's existing dedupe/metadata-detection/account-matching pipeline. Manual only —
# always explicitly triggered by a controller action, never a background scan.
class AccountStatement::PaperlessImporter
  AlreadyImportedError = Class.new(StandardError) do
    attr_reader :statement

    def initialize(statement)
      @statement = statement
      super("Paperless document has already been imported")
    end
  end

  # Paperless-ngx's `/download/` returns the *archived* PDF when one exists, which can disagree
  # with the original document's declared mime_type — so a generic sniff result gets one more
  # pass with no filename hint at all (magic bytes only) before we give up.
  GENERIC_CONTENT_TYPES = %w[application/octet-stream binary/octet-stream].freeze

  EXTENSION_FOR_CONTENT_TYPE = AccountStatement::ALLOWED_EXTENSION_CONTENT_TYPES
    .flat_map { |extension, content_types| content_types.map { |content_type| [ content_type, extension ] } }
    .to_h
    .freeze

  def initialize(paperless_connection, provider: nil)
    @paperless_connection = paperless_connection
    @provider = provider
  end

  def import!(document_id:, account: nil)
    id = coerce_document_id(document_id)
    raise AccountStatement::InvalidUploadError.new(:unknown_document) if id.nil?

    existing = paperless_connection.account_statements.find_by(paperless_document_id: id)
    raise AlreadyImportedError, existing if existing

    document = provider.document(id)
    bytes, response_content_type = provider.file(id, kind: :download)
    filename, content_type = derive_filename_and_content_type(id, document, bytes, response_content_type)

    prepared_upload = AccountStatement.prepare_content!(content: bytes, filename: filename, declared_content_type: content_type)

    AccountStatement.create_from_prepared_upload!(
      family: paperless_connection.family,
      account: account,
      prepared_upload: prepared_upload,
      attributes: {
        source: :paperless_import,
        paperless_connection: paperless_connection,
        paperless_document_id: id,
        institution_name_hint: correspondent_name(document)
      }.compact
    )
  end

  # Advisory pre-filter for the search results view only — the authoritative check is
  # prepare_content! against the real downloaded bytes, because of the archive/original
  # divergence noted above (a document whose *original* isn't a statement format can still be
  # importable if Paperless has archived it as a PDF).
  def self.importable_document?(document)
    mime_type = document["mime_type"]
    return true if mime_type.blank? # older Paperless list serializers omit it — fail open
    return true if document["archived_file_name"].present?

    AccountStatement::ALLOWED_CONTENT_TYPES.include?(mime_type)
  end

  private
    attr_reader :paperless_connection

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: paperless_connection.base_url,
        api_token: paperless_connection.api_token,
        verify_ssl: paperless_connection.verify_ssl
      )
    end

    def coerce_document_id(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def correspondent_name(document)
      correspondent_id = document["correspondent"]
      return nil if correspondent_id.blank?

      provider.correspondents[correspondent_id]
    end

    def derive_filename_and_content_type(id, document, bytes, response_content_type)
      original_name = document["original_file_name"]
      content_type = AccountStatement.detected_content_type(content: bytes, filename: original_name, declared_content_type: response_content_type)

      if GENERIC_CONTENT_TYPES.include?(content_type)
        content_type = AccountStatement.detected_content_type(content: bytes, filename: nil, declared_content_type: nil)
      end

      extension = EXTENSION_FOR_CONTENT_TYPE[content_type]
      raise AccountStatement::InvalidUploadError.new(:unsupported_type) if extension.blank?

      [ preferred_filename(id, original_name, extension, document["title"]), content_type ]
    end

    # Prefers, in order: the original filename (when its extension already matches the sniffed
    # type), a title-derived name, then a generic fallback. Deliberately NOT `.parameterize`d —
    # unlike Paperless::DocumentsController#filename_for, this filename is both what the vault
    # displays and what MetadataDetector#detect_from_filename mines for period/last4/institution
    # hints, and a readable "Kontoauszug 03 2026.pdf" parses at least as well as a slugified one.
    def preferred_filename(id, original_name, extension, title)
      if original_name.present? && File.extname(original_name.to_s).downcase == extension
        return sanitize_filename(original_name)
      end

      return sanitize_filename("#{title}#{extension}") if title.present?

      "paperless-document-#{id}#{extension}"
    end

    def sanitize_filename(name)
      cleaned = name.to_s.gsub(%r{[/\\]}, "-").gsub(/[\x00-\x1f]/, "").squish
      cleaned.truncate(200, omission: "")
    end
end
