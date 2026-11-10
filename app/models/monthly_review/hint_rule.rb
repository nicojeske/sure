# The rule a reviewer's hint asked for ("always map EON to Strom"), between
# the provider's raw Provider::LlmConcept::RuleProposal and the card's
# MonthlyReview::RuleSuggestion. It is stored in a hint suggestion's payload
# as "rule_proposal" => { "conditions", "actions", "pattern_key" } with the
# same condition and action hashes RulesController#new prefills, names
# already resolved to this family's ids.
#
# Rules can match on name, merchant and amount, and set category, tags,
# merchant and name. Anything else, notes included, or anything that does not
# resolve is dropped; a rule needs at least one condition and one action left.
class MonthlyReview::HintRule
  CONDITIONS = {
    "name" => { type: "transaction_name", operators: %w[like = starts_with ends_with] },
    "merchant" => { type: "transaction_merchant", operators: %w[=] },
    "amount" => { type: "transaction_amount", operators: %w[> >= < <= = !=] }
  }.freeze
  ACTIONS = {
    "category" => "set_transaction_category", "tags" => "set_transaction_tags",
    "merchant" => "set_transaction_merchant", "name" => "set_transaction_name"
  }.freeze
  # Operators shown as words; the others are shown as they are.
  OPERATOR_WORDS = { "like" => "contains", "starts_with" => "starts_with", "ends_with" => "ends_with" }.freeze

  # The payload hash for a raw proposal, nil when nothing usable is left.
  def self.normalize(raw, entry:, user:)
    return nil unless raw

    new(entry.account.family, user).normalize(raw, entry)
  end

  # The RuleSuggestion for a stored payload hash.
  def self.suggestion(stored, family:, user:)
    new(family, user).suggestion(stored)
  end

  def initialize(family, user)
    @family = family
    @user = user
  end

  def normalize(raw, entry)
    conditions = raw.conditions.filter_map { |condition| resolve_condition(condition) }
    actions = raw.actions.filter_map { |action| resolve_action(action) }
    return nil if conditions.empty? || actions.empty?

    { "conditions" => conditions, "actions" => actions, "pattern_key" => pattern_key(conditions, entry) }
  end

  def suggestion(stored)
    conditions = stored["conditions"].map(&:symbolize_keys)
    actions = stored["actions"].map(&:symbolize_keys)

    MonthlyReview::RuleSuggestion.new(
      conditions: conditions,
      actions: actions,
      summary: I18n.t(
        "monthly_reviews.rule_suggestion.hint_summary",
        conditions: conditions.map { |condition| describe_condition(condition) }.join(", "),
        actions: actions.map { |action| describe_action(action) }.join(", ")
      ),
      pattern_key: stored["pattern_key"]
    )
  end

  private
    attr_reader :family, :user

    def resolve_condition(condition)
      field = condition["field"]
      spec = CONDITIONS[field]
      return nil unless spec && spec[:operators].include?(condition["operator"])

      value = condition_value(field, condition["value"])
      { "condition_type" => spec[:type], "operator" => condition["operator"], "value" => value } if value
    end

    def condition_value(field, text)
      case field
      when "merchant" then find_by_name(family.available_merchants_for(user), text)&.id
      when "amount" then text if Float(text, exception: false)&.finite?
      else text
      end
    end

    def resolve_action(action)
      type = ACTIONS[action["field"]]
      return nil unless type

      value = case action["field"]
      when "category" then find_by_name(family.categories, action["value"])&.id
      when "merchant" then find_by_name(family.assignable_merchants_for(user), action["value"])&.id
      when "tags" then tag_ids(action["value"])
      else action["value"].presence
      end
      { "action_type" => type, "value" => value } if value.present?
    end

    def find_by_name(scope, name)
      return nil unless name.is_a?(String)

      scope.find_by(name: name) || scope.find_by(scope.arel_table[:name].lower.eq(name.downcase))
    end

    def tag_ids(names)
      downcased = Array(names).map(&:downcase)
      family.tags.select { |tag| downcased.include?(tag.name.downcase) }.map(&:id)
    end

    # The key a family dismisses this pattern by, as the automatic detector
    # keys it: the merchant, else the name stem, else the entry's own pattern.
    def pattern_key(conditions, entry)
      merchant = conditions.find { |condition| condition["condition_type"] == "transaction_merchant" }
      name = conditions.find { |condition| condition["condition_type"] == "transaction_name" }

      if merchant
        "merchant:#{merchant["value"]}"
      elsif name
        "name:#{(MonthlyReview::RuleSuggestionDetector.stem(name["value"]) || name["value"]).downcase}"
      else
        MonthlyReview::RuleSuggestionDetector.new(entry, user: user).pattern_key || "hint:#{entry.id}"
      end
    end

    def describe_condition(condition)
      field = condition[:condition_type].delete_prefix("transaction_")
      shown = field == "merchant" ? family.merchants.find_by(id: condition[:value])&.name : condition[:value]
      word = OPERATOR_WORDS[condition[:operator]]

      I18n.t(
        "monthly_reviews.rule_suggestion.condition",
        field: I18n.t("monthly_reviews.rule_suggestion.fields.#{field}"),
        operator: word ? I18n.t("monthly_reviews.rule_suggestion.operators.#{word}") : condition[:operator],
        value: shown
      )
    end

    def describe_action(action)
      field = action[:action_type].delete_prefix("set_transaction_")
      shown = case field
      when "category" then family.categories.find_by(id: action[:value])&.name
      when "merchant" then family.merchants.find_by(id: action[:value])&.name
      when "tags" then family.tags.where(id: action[:value]).alphabetically.pluck(:name).join(", ")
      else action[:value]
      end

      I18n.t("monthly_reviews.rule_suggestion.action", field: I18n.t("monthly_reviews.rule_suggestion.fields.#{field}"), value: shown)
    end
end
