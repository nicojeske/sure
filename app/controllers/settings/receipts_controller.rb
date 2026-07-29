class Settings::ReceiptsController < ApplicationController
  layout "settings"

  before_action :ensure_admin
  before_action :set_paperless_connection

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

  def show
    @breadcrumbs = [
      [ t("breadcrumbs.home"), root_path ],
      [ t("breadcrumbs.receipts"), nil ]
    ]
  end

  def update
    if @paperless_connection.update(paperless_connection_attributes)
      redirect_to settings_receipts_path, notice: t(".success")
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy
    @paperless_connection.destroy if @paperless_connection.persisted?
    redirect_to settings_receipts_path, notice: t(".disconnected")
  end

  def test_connection
    unless @paperless_connection.configured?
      return render json: { success: false, message: t(".not_configured") }
    end

    provider = Provider::Paperless.new(
      base_url: @paperless_connection.base_url,
      api_token: @paperless_connection.api_token,
      verify_ssl: @paperless_connection.verify_ssl
    )

    document_count = provider.test_connection
    @paperless_connection.update_columns(last_connected_at: Time.current, last_error_at: nil, last_error: nil)

    render json: { success: true, message: t(".success", count: document_count) }
  rescue Provider::Paperless::Error => e
    @paperless_connection.update_columns(last_error_at: Time.current, last_error: e.message)

    DebugLogEntry.capture(
      category: "provider_sync",
      level: "error",
      message: "Paperless connection test failed: #{e.message}",
      source: self.class.name,
      provider_key: "paperless",
      family: Current.family,
      metadata: { error_type: e.error_type }
    )

    message_key = ERROR_TYPE_MESSAGE_KEYS.fetch(e.error_type, :unknown)
    render json: { success: false, message: t(".errors.#{message_key}") }
  end

  private
    def set_paperless_connection
      @paperless_connection = Current.family.paperless_connection || Current.family.build_paperless_connection
    end

    def paperless_connection_attributes
      attrs = paperless_connection_params.to_h

      if attrs.key?("api_token")
        token = attrs["api_token"].to_s.strip
        if token == "********"
          attrs.delete("api_token")
        elsif token.blank?
          attrs["api_token"] = nil
        end
      end

      attrs
    end

    def paperless_connection_params
      params.require(:paperless_connection).permit(
        :base_url, :api_token, :verify_ssl, :auto_link_enabled, :match_window_days, :min_auto_link_score
      )
    end

    def ensure_admin
      redirect_to root_path, alert: t("settings.receipts.not_authorized") unless Current.user.admin?
    end
end
