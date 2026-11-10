# The family-wide language the AI writes stored values in (transaction names,
# notes, split names, new merchant names, bill names), independent of each
# member's interface language. Blank means "same as the interface language".
module Family::AiContentLanguage
  extend ActiveSupport::Concern

  # Shown in the language itself, so the option list reads the same to every
  # member whatever their interface language is.
  NATIVE_NAMES = {
    "ca" => "Català",
    "de" => "Deutsch",
    "en" => "English",
    "es" => "Español",
    "fr" => "Français",
    "hu" => "Magyar",
    "it" => "Italiano",
    "nb" => "Norsk bokmål",
    "nl" => "Nederlands",
    "pl" => "Polski",
    "pt-BR" => "Português (Brasil)",
    "pt-PT" => "Português (Portugal)",
    "ro" => "Română",
    "ru" => "Русский",
    "tr" => "Türkçe",
    "uk" => "Українська",
    "vi" => "Tiếng Việt",
    "zh-CN" => "简体中文",
    "zh-TW" => "繁體中文"
  }.freeze

  def self.locales
    I18n.available_locales.map(&:to_s) & LanguagesHelper::SUPPORTED_LOCALES
  end

  # [label, locale] pairs, sorted by label.
  def self.options
    locales.map { |locale| [ NATIVE_NAMES.fetch(locale, locale), locale ] }.sort_by(&:first)
  end

  included do
    normalizes :ai_content_language, with: ->(value) { value.presence }

    validates :ai_content_language, inclusion: { in: ->(_family) { Family::AiContentLanguage.locales } }, allow_nil: true
  end

  # The language `user` reads AI explanations in: their interface language.
  def ai_interface_locale_for(user)
    (user&.locale.presence || locale.presence || I18n.default_locale).to_s
  end

  # The language AI-written stored values are in when `user` runs the AI.
  def ai_content_locale_for(user)
    ai_content_language.presence || ai_interface_locale_for(user)
  end
end
