# Saves a review card's edit mode. The typed values become a proposal of
# their own (marked "edited", from the same source as the proposal the card
# showed) that is applied like an accepted one, so undo restores the previous
# values from its snapshot. Ids are kept to the family's own categories,
# merchants and tags; a blank field leaves the value as it is.
class MonthlyReview::ManualEdit
  attr_reader :entry, :user, :proposal

  # proposal: the suggestion the card showed, if any.
  def initialize(entry, user:, proposal: nil)
    @entry = entry
    @user = user
    @proposal = proposal
  end

  # attributes: the edit form's entry params, i.e. name, notes and
  # entryable_attributes (category_id, merchant_id, tag_ids).
  def save!(attributes)
    attributes = attributes.to_h.with_indifferent_access
    values = payload_for(attributes.except(:entryable_attributes).merge(attributes.fetch(:entryable_attributes, {})))

    suggestion = TransactionAnnotationSuggestion.create!(
      entry: entry, family: family, status: "ready",
      source: proposal&.source || "hint", hint_text: proposal&.hint_text, receipt_link: proposal&.receipt_link,
      input_hash: TransactionAnnotationSuggestion.input_hash_for(:edit, SecureRandom.uuid),
      payload: values.merge("edited" => true)
    )
    suggestion.apply!(user: user, fields: suggestion.proposed_fields)
  end

  private
    def family
      entry.account.family
    end

    def payload_for(attributes)
      {
        "name" => attributes[:name].presence,
        "notes" => attributes[:notes].presence,
        "category_id" => attributes[:category_id].presence && family.categories.find(attributes[:category_id]).id,
        "merchant_id" => attributes[:merchant_id].presence && family.assignable_merchants_for(user).find(attributes[:merchant_id]).id,
        "tag_ids" => family.tags.where(id: Array(attributes[:tag_ids]).compact_blank).pluck(:id)
      }
    end
end
