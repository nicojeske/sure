class UI::Transactions::Chart < ApplicationComponent
  VIEWS = %w[cumulative periodic].freeze
  GRANULARITIES = Transaction::ChartSeriesBuilder::GRANULARITIES

  attr_reader :search, :period, :link_params

  # `q`, `per_page`, `tab`, `granularity` carry the page's current state so the period
  # picker and the cumulative/periodic toggle never lose the user's active filters —
  # see TransactionsController's before_action :store_params!, which persists whatever
  # query string the request carries as the new "current filters" on every index hit.
  # `granularity` is only ever set here when the user explicitly picked one (the
  # controller passes nil otherwise), so an auto-derived granularity never gets
  # forced into the URL and keeps re-deriving as the period changes.
  def initialize(search:, period:, view: nil, granularity: nil, q: {}, per_page: nil, tab: nil)
    @search = search
    @period = period
    @view = view
    @explicit_granularity = granularity
    @link_params = { q: q, per_page: per_page, tab: tab, granularity: granularity }.compact_blank
  end

  def view
    @view.presence_in(VIEWS) || "cumulative"
  end

  def cumulative?
    view == "cumulative"
  end

  def family
    search.family
  end

  def currency
    family.currency
  end

  def series
    builder.cumulative_series
  end

  def bars
    builder.periodic_totals
  end

  # The effective granularity (explicit override, else auto-derived from the
  # period) — used to mark which segment is active even when nothing is in the URL.
  def granularity
    builder.granularity
  end

  def has_data?
    cumulative? ? series.any? : bars.any?
  end

  def net_total_money
    series.values.last&.value || Money.new(0, currency)
  end

  # Signed so a net positive (net income over the filter) isn't mistaken for a balance.
  def net_total_display
    money = net_total_money
    return money.format unless money.amount.positive?
    "+#{money.format}"
  end

  def trend
    series.trend
  end

  def link_params_for(overrides)
    link_params.merge(overrides).compact_blank
  end

  # Absolute I18n keys throughout this component — ViewComponent (4.12.0, this repo)
  # sets the render-time @virtual_path to the lowercased, underscored class name
  # ("ui/transactions/chart"), so relative t(".foo") calls resolve against scope
  # "ui.transactions.chart" and never find the capitalized "UI:" keys these
  # translations actually live under in config/locales/views/components/en.yml.
  # Absolute keys sidestep that entirely (see UI::Account::Chart#title for the same
  # established workaround).
  def title
    I18n.t("UI.transactions.chart.title")
  end

  def views_aria
    I18n.t("UI.transactions.chart.views_aria")
  end

  def view_label_for(key)
    I18n.t("UI.transactions.chart.views.#{key}")
  end

  def granularity_aria
    I18n.t("UI.transactions.chart.granularity_aria")
  end

  def granularity_label_for(key)
    I18n.t("UI.transactions.chart.granularity.#{key}")
  end

  def no_data_message
    I18n.t("UI.transactions.chart.no_data_available")
  end

  def comparison_label
    I18n.t("UI.transactions.chart.comparison_label")
  end

  def income_label
    I18n.t("UI.transactions.chart.income")
  end

  def expenses_label
    I18n.t("UI.transactions.chart.expenses")
  end

  private
    def builder
      @builder ||= Transaction::ChartSeriesBuilder.new(
        transactions_scope: search.transactions_scope,
        family: family,
        period: period,
        granularity: @explicit_granularity
      )
    end
end
