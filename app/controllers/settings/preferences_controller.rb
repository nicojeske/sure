class Settings::PreferencesController < ApplicationController
  layout "settings"

  before_action :require_admin!, only: :strip_name_prefixes

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)
    end
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
end
