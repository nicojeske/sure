require "test_helper"

class RuleSuggestionDismissalTest < ActiveSupport::TestCase
  test "deleting the user who dismissed a suggestion keeps the family's dismissal" do
    user = users(:family_admin)
    dismissal = user.family.rule_suggestion_dismissals.create!(user: user, pattern_key: "name:eon abschlag")

    user.destroy!

    assert_nil dismissal.reload.user_id
    assert_equal "name:eon abschlag", dismissal.pattern_key
  end
end
