# Saves the values typed into a review card's edit mode as the user's own
# edit (locked, user-modified, like the transaction drawer) and marks the
# entry reviewed. Only the fields this user may change are written, and ids
# are kept to the family's own categories, merchants and tags.
class MonthlyReview::ManualEdit
  attr_reader :entry, :user

  def initialize(entry, user:)
    @entry = entry
    @user = user
  end

  # attributes: name, notes, category_id, merchant_id, tag_ids (any subset).
  def save!(attributes)
    attributes = attributes.to_h.symbolize_keys
    permitted = TransactionAnnotationSuggestion::Applier.permitted_fields(entry, user)
    raise TransactionAnnotationSuggestion::Applier::Error, "Not allowed to annotate this transaction" if permitted.empty?

    entry_values = {}
    entry_values[:name] = attributes[:name] if permitted.include?("name") && attributes[:name].present?
    entry_values[:notes] = attributes[:notes].presence if permitted.include?("notes") && attributes.key?(:notes)
    transaction_values = transaction_values(attributes, permitted)

    Entry.transaction do
      entry.update!(entry_values.merge(entryable_attributes: transaction_values.merge(id: entry.entryable_id)))
      entry.lock_saved_attributes!
      entry.mark_user_modified!
      entry.transaction.lock_attr!(:tag_ids) if transaction_values.key?(:tag_ids)
      entry.mark_reviewed!(user)
    end
  end

  private
    def family
      entry.account.family
    end

    def transaction_values(attributes, permitted)
      values = {}

      if permitted.include?("category") && attributes.key?(:category_id) && entry.transaction.category_editable?
        values[:category_id] = attributes[:category_id].presence && family.categories.find(attributes[:category_id]).id
      end

      if permitted.include?("merchant") && attributes.key?(:merchant_id)
        values[:merchant_id] = attributes[:merchant_id].presence && family.assignable_merchants_for(user).find(attributes[:merchant_id]).id
      end

      if permitted.include?("tags") && attributes.key?(:tag_ids)
        values[:tag_ids] = family.tags.where(id: Array(attributes[:tag_ids]).compact_blank).pluck(:id)
      end

      values
    end
end
