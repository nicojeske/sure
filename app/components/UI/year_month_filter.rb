class UI::YearMonthFilter < ApplicationComponent
  # Shared year+month popover picker used by both the account activity feed
  # (UI::Account::ActivityDateFilter) and the global transactions index
  # (UI::Transactions::DateFilter). Each caller supplies its own href-building
  # strategy since the two encode the selected period differently (top-level
  # activity_year/activity_month params vs. q[start_date]/q[end_date]).
  attr_reader :years, :selected_year, :selected_month, :clear_href, :placement

  def initialize(years:, href_for:, clear_href:, selected_year: nil, selected_month: nil,
                 label: nil, active: nil, placement: "bottom-start")
    @years = years
    @href_builder = href_for
    @clear_href = clear_href
    @selected_year = selected_year
    @selected_month = selected_month
    @label = label
    @active = active
    @placement = placement
  end

  def href_for(year: nil, month: nil)
    @href_builder.call(year, month)
  end

  def months
    @months ||= (1..12).map { |m| [ m, I18n.t("date.month_names")[m] ] }
  end

  def trigger_label
    return @label if @label.present?

    if selected_year && selected_month
      I18n.t("date.month_names")[selected_month] + " #{selected_year}"
    elsif selected_year
      selected_year.to_s
    else
      # Absolute key: ViewComponent's @virtual_path lowercases the class name
      # ("ui/year_month_filter"), which would resolve a relative t(".foo") against
      # "ui.year_month_filter" and miss the capitalized "UI:" namespace these
      # translations live under in config/locales/views/components/en.yml (see
      # UI::Transactions::Chart#title for the same established workaround).
      I18n.t("UI.year_month_filter.all_time")
    end
  end

  def active?
    @active.nil? ? selected_year.present? : @active
  end

  def year_selected?(year)
    selected_year == year
  end

  def month_selected?(month)
    selected_year.present? && selected_month == month
  end
end
