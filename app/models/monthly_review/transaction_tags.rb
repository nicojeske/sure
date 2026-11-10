# The tags of transactions as sorted tag ids per transaction id, in one query.
module MonthlyReview::TransactionTags
  def self.tag_ids_by_transaction_id(transaction_ids)
    Tagging.where(taggable_type: "Transaction", taggable_id: transaction_ids).pluck(:taggable_id, :tag_id)
      .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }
  end
end
