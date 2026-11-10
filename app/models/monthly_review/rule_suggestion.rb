# A proposed new rule for a review card's transaction, never saved until the
# reviewer confirms it in the rule form. Conditions and actions are what
# RulesController#new prefills: conditions as { condition_type:, operator:,
# value: } and actions as { action_type:, value: } hashes. pattern_key names
# what the rule matches ("merchant:<id>" or "name:<normalized stem>"), the key
# a family dismisses a suggestion by.
MonthlyReview::RuleSuggestion = Data.define(:conditions, :actions, :summary, :pattern_key) do
  # The params for new_rule_path.
  def rule_params
    { resource_type: "transaction", conditions: conditions, actions: actions }
  end
end
