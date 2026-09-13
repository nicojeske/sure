# frozen_string_literal: true

# Manual, explicitly user-triggered search-and-import of Paperless-ngx documents into the
# Statement Vault. Reachable both from the vault (no account — lands in the unmatched inbox)
# and from an account's Statements tab (pre-scoped, links straight to that account). No
# background scan, no auto-linking — see docs/llm-guides/providers.md for the receipt-matching
# analog this mirrors.
class AccountStatements::PaperlessImportsController < ApplicationController
  include ActionView::RecordIdentifier
  include StatementManageable

  ERROR_TYPE_MESSAGE_KEYS = {
    unauthorized: :unauthorized,
    not_found: :not_found,
    rate_limited: :rate_limited,
    server_error: :server_error,
    unreachable: :unreachable,
    parse_error: :parse_error,
    untrusted_host: :untrusted_host,
    unknown: :unknown
  }.freeze

  before_action :ensure_statement_manager!
  before_action :set_paperless_connection
  before_action :set_account

  def new
    return if @account && !require_account_permission!(@account, :write, redirect_path: account_path(@account, tab: "statements"))

    @query = params[:q].presence || default_query
    @page = params[:page].presence&.to_i || 1
    load_search_results
  end

  def create
    return if @account && !require_account_permission!(@account, :write, redirect_path: account_path(@account, tab: "statements"))

    statement = importer.import!(document_id: params[:document_id], account: @account)

    stream_redirect_to success_path(statement), notice: t(".success", filename: statement.filename)
  rescue AccountStatement::PaperlessImporter::AlreadyImportedError => e
    render_import_error(t(".errors.already_imported", filename: e.statement.filename))
  rescue AccountStatement::DuplicateUploadError => e
    render_import_error(t(".errors.duplicate", filename: e.statement.filename))
  rescue AccountStatement::InvalidUploadError => e
    render_import_error(invalid_upload_message(e))
  rescue Provider::Paperless::Error => e
    capture_paperless_error(e, source: "AccountStatements::PaperlessImportsController#create")
    render_import_error(t("account_statements.paperless_imports.provider_errors.#{ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}"))
  rescue ActiveRecord::RecordInvalid => e
    render_import_error(e.record.errors.full_messages.to_sentence)
  end

  private
    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection
      head :not_found if @paperless_connection.nil? || !@paperless_connection.configured?
    end

    def set_account
      account_id = params[:account_id].presence
      return if account_id.blank?

      @account = Current.user.accessible_accounts.find(account_id)
    end

    def default_query
      @account&.institution_name.presence || @account&.name
    end

    def provider
      @provider ||= Provider::Paperless.new(
        base_url: @paperless_connection.base_url,
        api_token: @paperless_connection.api_token,
        verify_ssl: @paperless_connection.verify_ssl
      )
    end

    def load_search_results
      response = provider.search_documents(query: @query, page: @page, page_size: 25, ordering: "-created")
      @documents = response["results"] || []
      @next_page = response["next"].present? ? @page + 1 : nil
      @correspondents = provider.correspondents
      @imported_statement_ids = imported_statement_ids_for(@documents)
    rescue Provider::Paperless::Error => e
      capture_paperless_error(e, source: "AccountStatements::PaperlessImportsController#new")
      @documents = []
      @next_page = nil
      @correspondents = {}
      @imported_statement_ids = {}
      @search_error_message = t("account_statements.paperless_imports.provider_errors.#{ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)}")
    end

    def imported_statement_ids_for(documents)
      document_ids = documents.map { |document| document["id"] }
      return {} if document_ids.empty?

      Current.family.account_statements
        .where(paperless_connection_id: @paperless_connection.id, paperless_document_id: document_ids)
        .pluck(:paperless_document_id, :id)
        .to_h
    end

    def importer
      AccountStatement::PaperlessImporter.new(@paperless_connection, provider: provider)
    end

    def success_path(statement)
      if @account
        account_path(@account, tab: "statements")
      else
        account_statement_path(statement)
      end
    end

    def invalid_upload_message(error)
      t(
        "account_statements.paperless_imports.create.errors.invalid.#{error.reason}",
        max_size: AccountStatement::MAX_FILE_SIZE / 1.megabyte,
        default: t("account_statements.paperless_imports.create.errors.invalid.unsupported_type")
      )
    end

    def render_import_error(message)
      flash.now[:alert] = message
      render turbo_stream: flash_notification_stream_items, status: :unprocessable_entity
    end

    def capture_paperless_error(error, source:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: "Paperless statement import failed: #{error.message}",
        source: source,
        provider_key: "paperless",
        family: Current.family,
        metadata: { error_type: error.error_type, document_id: params[:document_id], account_id: @account&.id }
      )
    end
end
