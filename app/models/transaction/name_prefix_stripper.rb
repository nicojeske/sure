# Strips a card-aggregator/payment-processor prefix (e.g. "CRV*", "SUMUP *") from a
# raw provider descriptor. Originally lived as a hardcoded constant on
# EnableBankingEntry::Processor; extracted here so:
#
# 1. Other providers can reuse it without duplicating the regex.
# 2. A family can extend the built-in list with its own tokens (Family#stripped_name_prefixes),
#    which matters for aggregators like Curve that prefix every card purchase with "CRV*" and
#    have no universal industry-standard token list.
class Transaction::NamePrefixStripper
  # Small-merchant card terminal / virtual-card providers that prefix the payee with
  # "KEYWORD *". CRV is Curve (curve.com): it fronts every card purchase with "CRV*".
  DEFAULT_PREFIXES = %w[SUMUP SQ IZETTLE ZETTLE PAYPAL CRV].freeze

  # A prefixed value can itself be prefixed again (e.g. a Curve card topping up through
  # another aggregator: "CRV*SUMUP *BAKERY"), so strip repeatedly. Bounded so a
  # pathological/looping input can't spin forever.
  MAX_PASSES = 3

  def self.for_family(family)
    new(prefixes: DEFAULT_PREFIXES + Array(family&.stripped_name_prefixes))
  end

  attr_reader :prefixes

  def initialize(prefixes: DEFAULT_PREFIXES)
    @prefixes = Array(prefixes).map(&:to_s).reject(&:blank?).uniq
  end

  # Strips a leading "TOKEN *" (any amount of whitespace around the asterisk, matched
  # case-insensitively) for as long as one of the configured tokens matches, then falls
  # back to the original value if stripping would leave nothing behind.
  def call(value)
    return value if value.blank? || prefix_pattern.nil?

    stripped = value
    MAX_PASSES.times do
      new_value = stripped.sub(prefix_pattern, "").strip
      break if new_value == stripped
      stripped = new_value
    end

    stripped.presence || value
  end

  private

    def prefix_pattern
      return @prefix_pattern if defined?(@prefix_pattern)

      @prefix_pattern = prefixes.empty? ? nil : /\A(?:#{prefixes.map { |token| Regexp.escape(token) }.join("|")})\s*\*\s*/i
    end
end
