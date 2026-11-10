# A family's permanent "Never for this pattern" on a rule suggested during a
# monthly review. The pattern key is a MonthlyReview::RuleSuggestion#pattern_key
# ("merchant:<id>" or "name:<stem>"), so it holds across months and members.
# The dismissing user is kept only for reference and cleared when they go.
class RuleSuggestionDismissal < ApplicationRecord
  KEY_FORMAT = /\A(merchant|name):.+\z/

  belongs_to :family
  belongs_to :user, optional: true

  validates :pattern_key, presence: true, format: { with: KEY_FORMAT }, length: { maximum: 255 },
                          uniqueness: { scope: :family_id }
end
