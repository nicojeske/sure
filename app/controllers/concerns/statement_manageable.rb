# frozen_string_literal: true

module StatementManageable
  extend ActiveSupport::Concern

  private

    def ensure_statement_manager!
      return if AccountStatement.statement_manager?(Current.user)

      redirect_to accounts_path, alert: t("accounts.not_authorized")
    end
end
