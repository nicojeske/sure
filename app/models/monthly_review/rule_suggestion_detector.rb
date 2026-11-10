# Derives the automatic rule suggestion for a review card's entry from the
# family's reviewed history: at least MIN_MATCHES reviewed transactions, in at
# least MIN_MONTHS budget months, that share the entry's merchant (when it has
# one the user can pick in a rule) or else its name stem, and all have the same
# category. The rule matches on that merchant or stem and sets the category,
# plus the merchant, name and tags where all matches agree.
#
# The name stem is the raw name (before a review renamed it) up to its first
# word with a digit, so "EON 0423 Abschlag 04/26" has the stem "EON". It is a
# substring of every name it was derived from, so a "name contains" rule
# matches them.
class MonthlyReview::RuleSuggestionDetector
  MIN_MATCHES = 3
  MIN_MONTHS = 2

  Match = Data.define(:date, :name, :category_id, :merchant_id, :tag_ids)

  attr_reader :entry, :user

  # The name's leading words up to the first one with a digit, nil when they
  # hold fewer than three letters.
  def self.stem(name)
    words = name.to_s.split.take_while { |word| !word.match?(/\d/) }
    words.join(" ") if words.join.scan(/[[:alpha:]]/).size >= 3
  end

  # rule_handled: the card already knows; a transaction a rule handled gets no
  # suggestion.
  def initialize(entry, user:, rule_handled: false)
    @entry = entry
    @user = user
    @rule_handled = rule_handled
  end

  # The MonthlyReview::RuleSuggestion, or nil without enough evidence.
  def suggestion
    return nil if skip?
    return nil if matches.size < MIN_MATCHES || months < MIN_MONTHS

    category = uniform(:category_id) && family.categories.find_by(id: uniform(:category_id))
    return nil unless category

    MonthlyReview::RuleSuggestion.new(
      conditions: [ condition ],
      actions: actions(category),
      summary: I18n.t("monthly_reviews.rule_suggestion.summary", pattern: pattern_label, category: category.name, count: matches.size, months: months),
      pattern_key: pattern_key
    )
  end

  # What the suggested rule matches: "merchant:<id>" or "name:<stem>" (the
  # stem downcased), nil when the entry has neither.
  def pattern_key
    if merchant
      "merchant:#{merchant.id}"
    elsif stem
      "name:#{stem.downcase}"
    end
  end

  private
    attr_reader :rule_handled

    def skip?
      rule_handled || pattern_key.nil?
    end

    def family
      entry.account.family
    end

    def transaction
      entry.transaction
    end

    # The entry's merchant, when the user may use it in a rule condition.
    def merchant
      return @merchant if defined?(@merchant)

      @merchant = transaction.merchant_id && family.available_merchants_for(user).find_by(id: transaction.merchant_id)
    end

    def stem
      return @stem if defined?(@stem)

      @stem = self.class.stem(transaction.original_name || entry.name)
    end

    def pattern_label
      merchant ? merchant.name : stem
    end

    def condition
      if merchant
        { condition_type: "transaction_merchant", operator: "=", value: merchant.id }
      else
        { condition_type: "transaction_name", operator: "like", value: stem }
      end
    end

    # Category first, then whatever every match agrees on. A merchant
    # condition already fixes the merchant, so it is only set for a name stem.
    def actions(category)
      actions = [ { action_type: "set_transaction_category", value: category.id } ]

      merchant_id = uniform(:merchant_id)
      if merchant.nil? && merchant_id && family.assignable_merchants_for(user).exists?(id: merchant_id)
        actions << { action_type: "set_transaction_merchant", value: merchant_id }
      end

      name = uniform(:name)
      actions << { action_type: "set_transaction_name", value: name } if name

      tag_ids = uniform(:tag_ids)
      actions << { action_type: "set_transaction_tags", value: tag_ids } if tag_ids.present?

      actions
    end

    # The value every match has, nil when they differ.
    def uniform(attribute)
      values = matches.map(&attribute).uniq
      values.first if values.one?
    end

    def months
      @months ||= matches.map { |match| Budget.period_for(match.date, family: family).first }.uniq.size
    end

    def matches
      @matches ||= begin
        rows = history.pluck(
          "transactions.id", "entries.date", "entries.name", "transactions.category_id", "transactions.merchant_id",
          Arel.sql("transactions.extra ->> 'original_name'")
        )
        rows = rows.select { |row| self.class.stem(row[5].presence || row[2])&.downcase == stem.downcase } unless merchant
        tag_ids = Tagging.where(taggable_type: "Transaction", taggable_id: rows.map(&:first)).pluck(:taggable_id, :tag_id)
          .group_by(&:first).transform_values { |pairs| pairs.map(&:last).sort }

        rows.map do |id, date, name, category_id, merchant_id, _original_name|
          Match.new(date: date, name: name, category_id: category_id, merchant_id: merchant_id, tag_ids: tag_ids.fetch(id, []))
        end
      end
    end

    # The family's other reviewed transactions that may share the pattern.
    def history
      scope = family.entries.reviewed
        .where(entryable_type: "Transaction").where.not(id: entry.id)
        .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
        .merge(Entry.excluding_split_parents)

      if merchant
        scope.where(transactions: { merchant_id: merchant.id })
      else
        prefix = "#{Entry.sanitize_sql_like(stem.split.first)}%"
        scope.where("entries.name ILIKE :prefix OR transactions.extra ->> 'original_name' ILIKE :prefix", prefix: prefix)
      end
    end
end
