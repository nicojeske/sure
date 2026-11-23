class Settings::PreferencesController < ApplicationController
  layout "settings"

  before_action :require_admin!, only: :strip_name_prefixes

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
    if @user.preview_features_enabled?
      @web_push_public_key = WebPush::Client.vapid[:public_key] if WebPush::Client.configured?
      @web_push_registrations = @user.web_push_subscriptions.where(session: Current.session).pluck(:id, :endpoint_digest).to_h
    end
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled, :push_budget_warnings_enabled ]).fetch(:user, {})
    preview_changed = false

    @user.with_locked_preferences do |updated_prefs|
      if user_params.key?(:preview_features_enabled)
        enabled = ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
        preview_changed = updated_prefs["preview_features_enabled"] != enabled
        updated_prefs["preview_features_enabled"] = enabled
      end
      if user_params.key?(:push_budget_warnings_enabled) && updated_prefs["preview_features_enabled"] == true
        updated_prefs["push_budget_warnings_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:push_budget_warnings_enabled])
      end
    end

    sync_manual_loans if preview_changed
    redirect_to settings_preferences_path
  end

  # Retroactively cleans Enable Banking-sourced transaction/merchant names already in
  # the database, using the family's current stripped_name_prefixes -- the settings
  # page only ever strips new prefixes for new syncs. Runs in the background since a
  # family can have a large transaction history.
  def strip_name_prefixes
    StripNamePrefixesJob.perform_later(Current.family)

    DebugLogEntry.capture(
      category: "name_prefix_backfill",
      level: "info",
      message: "Transaction name prefix cleanup requested from settings",
      source: self.class.name,
      family: Current.family,
      user: Current.user
    )

    redirect_to settings_preferences_path, notice: t(".success")
  end

  private
    # The loan replay is gated on the family flag, and its result is stored in
    # the shared balance rows. Re-sync the manual loans so the toggle takes
    # effect now rather than at the next scheduled sync.
    def sync_manual_loans
      Current.family.accounts.manual.where(accountable_type: "Loan").find_each(&:sync_later)
    end
end
