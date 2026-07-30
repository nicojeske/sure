class UI::Transactions::Chart < ApplicationComponent
  VIEWS = %w[cumulative periodic].freeze

  attr_reader :search, :period, :link_params

  # `q`, `per_page`, `tab` carry the page's current state so the period picker and
  # the cumulative/periodic toggle never lose the user's active filters — see
  # TransactionsController's before_action :store_params!, which persists whatever
  # query string the request carries as the new "current filters" on every index hit.
  def initialize(search:, period:, view: nil, q: {}, per_page: nil, tab: nil)
    @search = search
    @period = period
    @view = view
    @link_params = { q: q, per_page: per_page, tab: tab }.compact_blank
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

  private
    def builder
      @builder ||= Transaction::ChartSeriesBuilder.new(
        transactions_scope: search.transactions_scope,
        family: family,
        period: period
      )
    end
end
