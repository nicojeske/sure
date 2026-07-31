class UI::Transactions::DateFilter < ApplicationComponent
  # Adapts the shared UI::YearMonthFilter popover to the transactions index, which
  # encodes its date range as q[start_date]/q[end_date] (unlike the account activity
  # feed's top-level activity_year/activity_month params) so it composes with the
  # rest of Transaction::Search, session-restored filters, and filter chips for free.
  attr_reader :selected_year, :selected_month, :custom_label

  def initialize(start_date:, end_date:)
    @raw_start = parse_date(start_date)
    @raw_end = parse_date(end_date)
    @selected_year, @selected_month, @custom_label = derive_selection
  end

  def years
    @years ||= begin
      oldest = Current.family&.oldest_entry_date&.year || Date.current.year
      (oldest..Date.current.year).to_a.reverse
    end
  end

  def active?
    @raw_start.present? || @raw_end.present?
  end

  def href_for(year: nil, month: nil)
    q = current_q.except("start_date", "end_date")

    if year
      period = calendar_period(year, month)
      q["start_date"] = period.start_date.iso8601
      q["end_date"] = period.end_date.iso8601
    end

    build_path(q)
  end

  def clear_href
    build_path(current_q.except("start_date", "end_date"))
  end

  private
    def parse_date(value)
      Date.parse(value) if value.present?
    rescue ArgumentError, TypeError
      nil
    end

    # Reverse-maps the raw start/end dates back into a year/month selection so the
    # picker can highlight the matching row. Anything that isn't exactly a calendar
    # month or a calendar year (e.g. the Date tab's free-form inputs) is shown as a
    # "Custom range" label instead of a false-positive year/month match.
    def derive_selection
      return [ nil, nil, nil ] unless @raw_start && @raw_end

      if @raw_start == @raw_start.beginning_of_month && @raw_end == @raw_start.end_of_month
        [ @raw_start.year, @raw_start.month, nil ]
      elsif @raw_start == Date.new(@raw_start.year, 1, 1) && @raw_end == Date.new(@raw_start.year, 12, 31)
        [ @raw_start.year, nil, nil ]
      else
        [ nil, nil, I18n.t("UI.transactions.date_filter.custom_range") ]
      end
    end

    def calendar_period(year, month)
      if month
        start_date = Date.new(year, month, 1)
        end_date = start_date.end_of_month
      else
        start_date = Date.new(year, 1, 1)
        end_date = Date.new(year, 12, 31)
      end

      Period.custom(start_date: start_date, end_date: end_date)
    end

    def current_q
      (helpers.request.query_parameters["q"] || {}).stringify_keys
    end

    def build_path(q)
      base_params = helpers.request.query_parameters.except("page", "q").to_h
      base_params["q"] = q if q.present?

      query = base_params.to_query
      query.empty? ? helpers.transactions_path : "#{helpers.transactions_path}?#{query}"
    end
end
