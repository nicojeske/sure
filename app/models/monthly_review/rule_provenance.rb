# Which review fields of the given entries hold a value a rule set: a "rule"
# data enrichment exists for the field's attribute and its value still equals
# the current one (tags compared as a set). Changing the value by hand or
# through the AI makes them differ, so no other bookkeeping is needed.
#
# Enrichments, tags and rules are loaded for all entries at once, so the
# month's list can ask about every row.
class MonthlyReview::RuleProvenance
  FIELD_ATTRIBUTES = TransactionAnnotationSuggestion::FIELD_ATTRIBUTES.slice("name", "merchant", "category", "tags").freeze

  def initialize(family, entries)
    @family = family
    @entries = entries.to_a
  end

  # Rule-set field key => the rule that set it, in TransactionAnnotationSuggestion::FIELDS
  # order. The rule is nil when the enrichment predates rule ids or the rule
  # was deleted since.
  def rules_by_field(entry)
    fields_by_entry_id.fetch(entry.id, {})
  end

  def rule_handled?(entry)
    rules_by_field(entry).any?
  end

  private
    attr_reader :family, :entries

    def fields_by_entry_id
      @fields_by_entry_id ||= entries.to_h { |entry| [ entry.id, fields_for(entry) ] }
    end

    def fields_for(entry)
      FIELD_ATTRIBUTES.each_with_object({}) do |(key, attribute), fields|
        enrichable_id = attribute == "name" ? entry.id : entry.entryable_id
        enrichment = enrichments[[ enrichable_id, attribute ]]
        next unless enrichment && same_value?(enrichment.value, current_value(entry, attribute))

        fields[key] = rules[enrichment.metadata&.dig("rule_id")]
      end
    end

    def current_value(entry, attribute)
      case attribute
      when "name" then entry.name
      when "tag_ids" then tag_ids_by_transaction_id.fetch(entry.entryable_id, [])
      else entry.entryable[attribute]
      end
    end

    def same_value?(stored, current)
      if current.is_a?(Array)
        Array(stored).map(&:to_s).sort == current.map(&:to_s).sort
      else
        stored.present? && stored.to_s == current.to_s
      end
    end

    # [enrichable id, attribute name] => the "rule" enrichment.
    def enrichments
      @enrichments ||= begin
        transaction_attributes = FIELD_ATTRIBUTES.values - [ "name" ]
        DataEnrichment.rule.where(enrichable_type: "Entry", enrichable_id: entries.map(&:id), attribute_name: "name")
          .or(DataEnrichment.rule.where(enrichable_type: "Transaction", enrichable_id: transaction_ids, attribute_name: transaction_attributes))
          .index_by { |enrichment| [ enrichment.enrichable_id, enrichment.attribute_name ] }
      end
    end

    def rules
      @rules ||= family.rules.where(id: enrichments.values.filter_map { |enrichment| enrichment.metadata&.dig("rule_id") }.uniq).index_by(&:id)
    end

    def tag_ids_by_transaction_id
      @tag_ids_by_transaction_id ||= begin
        tagged_ids = enrichments.values.select { |enrichment| enrichment.attribute_name == "tag_ids" }.map(&:enrichable_id)
        MonthlyReview::TransactionTags.tag_ids_by_transaction_id(tagged_ids)
      end
    end

    def transaction_ids
      entries.select { |entry| entry.entryable_type == "Transaction" }.map(&:entryable_id)
    end
end
