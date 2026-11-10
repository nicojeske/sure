# Fills a new, unsaved rule with the conditions and actions a link asks the
# rule form to start with, e.g. a rule suggestion accepted during the monthly
# review. Entries the form could not show as given (an unknown type, an
# operator the filter lacks, a value outside the options) are skipped, since
# they come from a URL and the user still reviews the form before saving.
class Rule::FormPrefill
  def initialize(rule)
    @rule = rule
  end

  # Each list is an array of hashes, or a hash keyed by index as a query
  # string may carry it. Conditions take condition_type, operator and value;
  # actions take action_type and value (an array for a multi-select action).
  def apply(conditions: nil, actions: nil)
    entries(conditions).each { |attributes| build_condition(attributes) }
    entries(actions).each { |attributes| build_action(attributes) }
    rule
  end

  private
    attr_reader :rule

    def entries(list)
      list = list.values if list.is_a?(Hash)
      Array(list).select { |entry| entry.is_a?(Hash) }.map(&:with_indifferent_access)
    end

    def build_condition(attributes)
      filter = rule.condition_filters.find { |candidate| candidate.key == attributes[:condition_type] }
      return unless filter

      operator = attributes[:operator]
      return unless filter.operators.any? { |_label, key| key == operator }

      if Rule::ConditionFilter::VALUELESS_OPERATORS.include?(operator)
        rule.conditions.build(condition_type: filter.key, operator: operator)
        return
      end

      value = attributes[:value]
      options = rule.option_list([ :condition, filter.key ]) { filter.options }
      return unless acceptable_value?(value, filter.type, options)
      return if Rule::ConditionFilter::REGEX_OPERATORS.include?(operator) && Rule::SafeRegex.error_for(value)

      rule.conditions.build(condition_type: filter.key, operator: operator, value: value)
    end

    def build_action(attributes)
      executor = rule.action_executors.find { |candidate| candidate.key == attributes[:action_type] }
      return unless executor

      value = attributes[:value]
      options = rule.option_list([ :action, executor.key ]) { executor.options }

      case executor.type
      when "function"
        rule.actions.build(action_type: executor.key)
      when "select", "text"
        rule.actions.build(action_type: executor.key, value: value) if acceptable_value?(value, executor.type, options)
      when "multi_select"
        ids = Array(value).select { |id| acceptable_value?(id, executor.type, options) }
        rule.actions.build(action_type: executor.key, value: ids) if ids.any?
      end
    end

    def acceptable_value?(value, type, options)
      return false unless value.is_a?(String) && value.present? && DatabaseTextValidator.acceptable?(value)

      case type
      when "select", "multi_select" then options.to_a.any? { |_label, id| id.to_s == value }
      when "number" then Float(value, exception: false)&.finite?
      else true
      end
    end
end
