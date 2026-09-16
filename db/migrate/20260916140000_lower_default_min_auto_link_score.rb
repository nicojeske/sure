# frozen_string_literal: true

# The OCR-only matching ceiling without a mapped custom field is exactly OCR_AMOUNT_WEIGHT (0.45)
# + DATE_WEIGHT (0.25) + CORRESPONDENT_WEIGHT (0.20) = 0.90 (see PaperlessConnection::Scoring) — the
# old default of 0.9 meant a perfect date *and* a perfect correspondent match were both required to
# auto-link. Lowering the default to 0.70 (== OCR_AMOUNT_WEIGHT + DATE_WEIGHT) makes a confident
# amount match plus an exact/near date sufficient on its own; correspondent similarity becomes a
# bonus that helps reach the bar faster (e.g. with a looser date match) rather than a hard
# requirement.
class LowerDefaultMinAutoLinkScore < ActiveRecord::Migration[7.2]
  def up
    change_column_default :paperless_connections, :min_auto_link_score, from: 0.9, to: 0.7

    # Only rows still sitting at the old default -- indistinguishable from a family that
    # deliberately chose exactly 0.9, but nobody picks that value on purpose (it's not a round
    # number with any meaning of its own; it only ever got there by never touching the setting).
    execute "UPDATE paperless_connections SET min_auto_link_score = 0.7 WHERE min_auto_link_score = 0.9"
  end

  def down
    change_column_default :paperless_connections, :min_auto_link_score, from: 0.7, to: 0.9
  end
end
