class UI::Account::ActivityDateFilter < ApplicationComponent
  attr_reader :account, :selected_year, :selected_month

  def initialize(account:, selected_year: nil, selected_month: nil)
    @account = account
    @selected_year = selected_year
    @selected_month = selected_month
  end

  def years
    @years ||= begin
      oldest = account.entries.minimum(:date)&.year || Date.current.year
      newest = Date.current.year
      (oldest..newest).to_a.reverse
    end
  end

  def href_for(year: nil, month: nil)
    base_params = helpers.request.query_parameters.except("activity_year", "activity_month", "page").to_h

    if year
      base_params[:activity_year] = year
      base_params[:activity_month] = month if month
    end

    "#{helpers.account_path(account)}?#{base_params.to_query}"
  end

  def clear_href
    base_params = helpers.request.query_parameters.except("activity_year", "activity_month", "page").to_h
    query = base_params.to_query
    query.empty? ? helpers.account_path(account) : "#{helpers.account_path(account)}?#{query}"
  end
end
