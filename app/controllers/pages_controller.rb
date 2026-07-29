class PagesController < ApplicationController
  include Periodable

  # Per-widget dashboard layout guardrails. Deterministic defaults the masonry
  # packer reads; users may override a grow widget's height via presets.
  #   col_span:   "single" | "full" (full spans both columns in 2-col mode)
  #   grow:       true for charts that should fill an allotted height,
  #               false for content-sized widgets (tables, stat grids)
  #   min_height: floor in px
  DASHBOARD_SECTION_LAYOUTS = {
    # Width-toggleable but full by default: the feed is much shorter than any
    # other single-width widget, so defaulting to half leaves a grid hole the
    # masonry can't backfill (dense placement needs a later card short enough
    # to fit beside it, and none is). Users who pair it manually can go half.
    "insights_feed"      => { col_span: "full",   grow: false, min_height: 0, width_toggle: true },
    "cashflow_sankey"    => { col_span: "full",   grow: false, min_height: 384, width_toggle: true },
    "money_flow"         => { col_span: "single", grow: false, min_height: 0,   width_toggle: true },
    "outflows_donut"     => { col_span: "single", grow: false, min_height: 0 },
    "investment_summary" => { col_span: "single", grow: false, min_height: 0, width_toggle: true },
    "net_worth_chart"    => { col_span: "single", grow: true,  min_height: 208, width_toggle: true },
    "balance_sheet"      => { col_span: "single", grow: false, min_height: 0, width_toggle: true }
  }.freeze

  # Number of consecutive months (ending at the selected month) shown as
  # bars in the "money_flow" dashboard widget.
  MONEY_FLOW_CHART_MONTHS = 6

  # Selectable height presets (px) for grow widgets.
  DASHBOARD_HEIGHT_PRESETS = { "compact" => 208, "auto" => 288, "tall" => 416 }.freeze
  DEFAULT_HEIGHT_PRESET = "auto"

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    @balance_sheet = Current.family.balance_sheet
    @investment_statement = Current.family.investment_statement
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo

    # Use IncomeStatement for all cashflow data (now includes categorized trades)
    income_statement = Current.family.income_statement

    @cashflow_sankey_data = income_statement.cashflow_sankey_data(period: @period)
    @outflows_data = build_outflows_donut_data(income_statement.net_category_totals(period: @period))
    # Preview-gated: skip the query outright rather than loading rows the
    # section won't be built from.
    @feed_insights = preview_features_enabled? ? Current.family.insights.visible.ordered.limit(3) : Insight.none

    @money_flow_accounts = income_statement.eligible_accounts
    @money_flow_month = money_flow_month_param
    @money_flow_account_ids = money_flow_account_ids_param
    @money_flow_data = build_money_flow_data(income_statement, @money_flow_month, @money_flow_account_ids)

    @dashboard_sections = build_dashboard_sections

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.dashboard"), nil ] ]
  end

  def intro
    @breadcrumbs = [ [ t("breadcrumbs.home"), chats_path ], [ t("breadcrumbs.intro"), nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def changelog
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: t("pages.release_notes_unavailable.name"),
        published_at: Date.current,
        body: t("pages.release_notes_unavailable.body_html")
      }
    end

    render layout: "settings"
  end

  def feedback
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  def privacy
    render layout: "blank"
  end

  def terms
    render layout: "blank"
  end

  private
    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections].respond_to?(:to_unsafe_h)
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order].is_a?(Array)
        permitted["dashboard_section_layout"] = prefs[:dashboard_section_layout].to_unsafe_h if prefs[:dashboard_section_layout].respond_to?(:to_unsafe_h)
      end
    end

    # Preview-gated, and omitted from the section list entirely rather than
    # left in it with `visible: false`. Dropping it here means the two
    # downstream behaviors fall out for free: the saved-order lookup finds
    # nothing to map, and the insights_feed unshift special-case never fires.
    def insights_feed_section
      return nil unless preview_features_enabled?

      {
        key: "insights_feed",
        title: "pages.dashboard.insights_feed.title",
        partial: "pages/dashboard/insights_feed",
        layout: section_layout("insights_feed"),
        locals: { insights: @feed_insights },
        visible: @feed_insights.any?,
        collapsible: true
      }
    end

    def build_dashboard_sections
      all_sections = [
        insights_feed_section,
        {
          key: "cashflow_sankey",
          title: "pages.dashboard.cashflow_sankey.title",
          partial: "pages/dashboard/cashflow_sankey",
          layout: section_layout("cashflow_sankey"),
          locals: { sankey_data: @cashflow_sankey_data, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "money_flow",
          title: "pages.dashboard.money_flow.title",
          partial: "pages/dashboard/money_flow",
          layout: section_layout("money_flow"),
          locals: { money_flow_data: @money_flow_data, accounts: @money_flow_accounts, col_span: section_layout("money_flow")[:col_span] },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "outflows_donut",
          title: "pages.dashboard.outflows_donut.title",
          partial: "pages/dashboard/outflows_donut",
          layout: section_layout("outflows_donut"),
          locals: { outflows_data: @outflows_data, period: @period },
          visible: @accounts.any? && @outflows_data[:categories].present?,
          collapsible: true
        },
        {
          key: "investment_summary",
          title: "pages.dashboard.investment_summary.title",
          partial: "pages/dashboard/investment_summary",
          layout: section_layout("investment_summary"),
          locals: { investment_statement: @investment_statement, period: @period },
          visible: @accounts.any? && @investment_statement.investment_accounts.any?,
          collapsible: true
        },
        {
          key: "net_worth_chart",
          title: "pages.dashboard.net_worth_chart.title",
          partial: "pages/dashboard/net_worth_chart",
          layout: section_layout("net_worth_chart"),
          locals: { balance_sheet: @balance_sheet, period: @period },
          visible: @accounts.any?,
          collapsible: true
        },
        {
          key: "balance_sheet",
          title: "pages.dashboard.balance_sheet.title",
          partial: "pages/dashboard/balance_sheet",
          layout: section_layout("balance_sheet"),
          locals: { balance_sheet: @balance_sheet },
          visible: @accounts.any?,
          collapsible: true
        }
      ].compact

      # Order sections according to user preference
      section_order = Current.user.dashboard_section_order
      ordered_sections = section_order.map do |key|
        all_sections.find { |s| s[:key] == key }
      end.compact

      # Add any new sections that aren't in the saved order (future-proofing).
      # The insights feed leads instead of appending: it's a proactive surface,
      # and appending would bury it below the fold for every family with a
      # saved order. Users can still drag it back down — that choice persists.
      all_sections.each do |section|
        next if ordered_sections.include?(section)

        if section[:key] == "insights_feed"
          ordered_sections.unshift(section)
        else
          ordered_sections << section
        end
      end

      ordered_sections
    end

    # Resolves a section's layout guardrails, applying the user's height preset
    # override (falling back to the deterministic default) for grow widgets.
    def section_layout(key)
      base = DASHBOARD_SECTION_LAYOUTS.fetch(key, { col_span: "single", grow: false, min_height: 0, width_toggle: false })
      preset = Current.user.dashboard_section_height(key)
      preset = DEFAULT_HEIGHT_PRESET unless DASHBOARD_HEIGHT_PRESETS.key?(preset)

      col_span = base[:col_span]
      if base[:width_toggle]
        user_span = Current.user.dashboard_section_width(key)
        col_span = user_span if %w[single full].include?(user_span)
      end

      base.merge(col_span: col_span, height_preset: preset, height_px: DASHBOARD_HEIGHT_PRESETS.fetch(preset))
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_outflows_donut_data(net_totals)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def money_flow_month_param
      current_month = Date.current.beginning_of_month
      month = Date.strptime(params[:money_flow_month], "%Y-%m-%d").beginning_of_month
      # Clamp future months: build_money_flow_data caps each bar's end_date at
      # Date.current, which would otherwise be earlier than a future month's
      # start_date and blow up Period.custom's date-range validation.
      month > current_month ? current_month : month
    rescue ArgumentError, TypeError
      current_month
    end

    # nil means "all accessible accounts" (the widget's default, unfiltered state)
    def money_flow_account_ids_param
      ids = Array(params[:money_flow_account_ids]).reject(&:blank?)
      eligible_ids = @money_flow_accounts.map { |a| a.id.to_s }
      ids &= eligible_ids
      ids.presence
    end

    def build_money_flow_data(income_statement, selected_month, account_ids)
      months = (MONEY_FLOW_CHART_MONTHS - 1).downto(0).map { |i| selected_month - i.months }

      selected_period = nil
      selected_totals = nil

      bars = months.map do |month_start|
        # Cap at today so an in-progress month (most commonly the current one)
        # doesn't report totals for its not-yet-arrived days.
        end_date = [ month_start.end_of_month, Date.current ].min
        period = Period.custom(start_date: month_start, end_date: end_date)
        totals = income_statement.totals_for(period, account_ids: account_ids)

        if month_start == selected_month
          selected_period = period
          selected_totals = totals
        end

        {
          date: month_start,
          label: I18n.l(month_start, format: :short_month_year),
          income: totals.income_money.amount.to_f.round(2),
          expense: totals.expense_money.amount.to_f.round(2),
          highlighted: month_start == selected_month,
          partial: end_date < month_start.end_of_month
        }
      end

      {
        bars: bars,
        period: selected_period,
        month: selected_month,
        income: selected_totals.income_money,
        expense: selected_totals.expense_money,
        balance: selected_totals.income_money - selected_totals.expense_money,
        account_ids: account_ids
      }
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
