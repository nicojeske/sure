class Settings::AiContentLanguagesController < ApplicationController
  before_action :require_admin!

  def update
    if Current.family.update(ai_content_language: params.require(:family)[:ai_content_language])
      redirect_to settings_ai_prompts_path, notice: t(".success")
    else
      redirect_to settings_ai_prompts_path, alert: t(".invalid")
    end
  end
end
