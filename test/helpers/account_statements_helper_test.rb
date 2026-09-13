require "test_helper"

class AccountStatementsHelperTest < ActionView::TestCase
  setup do
    @account = accounts(:depository)
  end

  test "reconciliation label falls back for invalid checks" do
    opening_balance = I18n.t("account_statements.reconciliation.checks.opening_balance")
    closing_balance = I18n.t("account_statements.reconciliation.checks.closing_balance")
    unknown_check = I18n.t("account_statements.reconciliation.checks.unknown_check")

    assert_equal opening_balance, account_statement_reconciliation_label({ key: "opening_balance" })
    assert_equal closing_balance, account_statement_reconciliation_label({ "key" => "closing_balance" })
    assert_equal unknown_check, account_statement_reconciliation_label({})
    assert_equal unknown_check, account_statement_reconciliation_label(nil)
    assert_equal unknown_check, account_statement_reconciliation_label([])
  end

  test "coverage link path is nil for missing and not_expected months" do
    [ "missing", "not_expected" ].each do |status|
      month = AccountStatement::Coverage::Month.new(date: Date.new(2024, 1, 1), status: status, statements: [], ambiguous_statements: [])

      assert_nil account_statement_coverage_link_path(@account, month)
    end
  end

  test "coverage link path targets the only linked statement" do
    statement = create_statement(@account, filename: "one.csv")
    month = AccountStatement::Coverage::Month.new(date: Date.new(2024, 2, 1), status: "covered", statements: [ statement ], ambiguous_statements: [])

    assert_equal account_statement_path(statement), account_statement_coverage_link_path(@account, month)
  end

  test "coverage link path targets the filtered vault for several linked statements" do
    first = create_statement(@account, filename: "first.csv", content: "date,amount\n2024-02-01,1\n")
    second = create_statement(@account, filename: "second.csv", content: "date,amount\n2024-02-02,2\n")
    month = AccountStatement::Coverage::Month.new(date: Date.new(2024, 2, 1), status: "duplicate", statements: [ first, second ], ambiguous_statements: [])

    expected = account_statements_path(linked_account_id: @account.id, linked_month: "2024-02")
    assert_equal expected, account_statement_coverage_link_path(@account, month)
  end

  test "coverage link path prefers linked statements over suggestions" do
    linked = create_statement(@account, filename: "linked.csv")
    suggestion_one = create_statement(nil, filename: "suggestion_1.csv", content: "date,amount\n2024-02-03,3\n")
    suggestion_two = create_statement(nil, filename: "suggestion_2.csv", content: "date,amount\n2024-02-04,4\n")
    month = AccountStatement::Coverage::Month.new(
      date: Date.new(2024, 2, 1), status: "covered",
      statements: [ linked ], ambiguous_statements: [ suggestion_one, suggestion_two ]
    )

    assert_equal account_statement_path(linked), account_statement_coverage_link_path(@account, month)
  end

  test "coverage link path targets a lone suggested statement" do
    suggested = create_statement(nil, filename: "suggested.csv")
    month = AccountStatement::Coverage::Month.new(date: Date.new(2024, 3, 1), status: "ambiguous", statements: [], ambiguous_statements: [ suggested ])

    assert_equal account_statement_path(suggested), account_statement_coverage_link_path(@account, month)
  end

  test "coverage link path is nil when only several suggestions exist" do
    suggestion_one = create_statement(nil, filename: "suggestion_1.csv", content: "date,amount\n2024-03-01,1\n")
    suggestion_two = create_statement(nil, filename: "suggestion_2.csv", content: "date,amount\n2024-03-02,2\n")
    month = AccountStatement::Coverage::Month.new(
      date: Date.new(2024, 3, 1), status: "ambiguous",
      statements: [], ambiguous_statements: [ suggestion_one, suggestion_two ]
    )

    assert_nil account_statement_coverage_link_path(@account, month)
  end

  test "coverage aria label names the month and status" do
    month = AccountStatement::Coverage::Month.new(date: Date.new(2024, 2, 1), status: "covered", statements: [], ambiguous_statements: [])

    label = account_statement_coverage_aria_label(month)

    assert_includes label, "Feb 2024"
    assert_includes label, I18n.t("account_statements.coverage.status.covered")
  end

  private
    def create_statement(account, filename:, content: "date,amount\n2024-01-01,1\n")
      AccountStatement.create_from_upload!(
        family: @account.family,
        account: account,
        file: uploaded_file(filename: filename, content_type: "text/csv", content: content)
      )
    end
end
