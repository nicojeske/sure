# The rule whose action is running, so the "rule" data enrichments it writes
# record which rule set the value (metadata "rule_id") without every action
# executor having to pass it along. Enrichments written before this existed
# have no rule id.
class Rule::Provenance < ActiveSupport::CurrentAttributes
  attribute :rule_id

  def self.metadata_for(source, metadata)
    return metadata unless source.to_s == "rule" && rule_id

    metadata.merge("rule_id" => rule_id)
  end
end
