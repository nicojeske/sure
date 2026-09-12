require "test_helper"

class Transaction::NamePrefixStripperTest < ActiveSupport::TestCase
  test "strips a built-in default prefix" do
    stripper = Transaction::NamePrefixStripper.new

    assert_equal "ALDI SUED", stripper.call("CRV*ALDI SUED")
    assert_equal "HERR DR. EISENSTADT 7000", stripper.call("SUMUP  *HERR DR. EISENSTADT 7000")
  end

  test "matches prefixes case-insensitively" do
    stripper = Transaction::NamePrefixStripper.new

    assert_equal "Aldi Sued", stripper.call("crv*Aldi Sued")
  end

  test "leaves a value with no matching prefix unchanged" do
    stripper = Transaction::NamePrefixStripper.new

    assert_equal "ALDI SUED", stripper.call("ALDI SUED")
  end

  test "returns blank values unchanged" do
    stripper = Transaction::NamePrefixStripper.new

    assert_nil stripper.call(nil)
    assert_equal "", stripper.call("")
  end

  test "falls back to the original value when stripping would leave nothing" do
    stripper = Transaction::NamePrefixStripper.new

    assert_equal "CRV*", stripper.call("CRV*")
    assert_equal "CRV* ", stripper.call("CRV* ")
  end

  test "strips repeated prefixes up to MAX_PASSES" do
    stripper = Transaction::NamePrefixStripper.new

    assert_equal "BAKERY", stripper.call("CRV*SUMUP *BAKERY")
  end

  test "accepts family-supplied prefixes in addition to the defaults" do
    stripper = Transaction::NamePrefixStripper.new(prefixes: Transaction::NamePrefixStripper::DEFAULT_PREFIXES + [ "REVOLT" ])

    assert_equal "Bakery Vienna", stripper.call("REVOLT*Bakery Vienna")
    # Built-in defaults still apply alongside the custom one
    assert_equal "ALDI SUED", stripper.call("CRV*ALDI SUED")
  end

  test "only strips a custom prefix that was actually configured" do
    stripper = Transaction::NamePrefixStripper.new(prefixes: Transaction::NamePrefixStripper::DEFAULT_PREFIXES)

    assert_equal "REVOLT*Bakery Vienna", stripper.call("REVOLT*Bakery Vienna")
  end

  test "escapes regex metacharacters in a custom prefix so it never raises" do
    stripper = Transaction::NamePrefixStripper.new(prefixes: [ "A+B" ])

    assert_equal "Bakery", stripper.call("A+B*Bakery")
    assert_equal "A.B*Bakery", stripper.call("A.B*Bakery")
  end

  test ".for_family combines the defaults with the family's configured prefixes" do
    family = Family.new(stripped_name_prefixes: [ "REVOLT" ])

    stripper = Transaction::NamePrefixStripper.for_family(family)

    assert_equal "Bakery Vienna", stripper.call("REVOLT*Bakery Vienna")
    assert_equal "ALDI SUED", stripper.call("CRV*ALDI SUED")
  end

  test ".for_family handles a nil family" do
    stripper = Transaction::NamePrefixStripper.for_family(nil)

    assert_equal "ALDI SUED", stripper.call("CRV*ALDI SUED")
  end
end
