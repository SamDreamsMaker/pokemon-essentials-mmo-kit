require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/config"

# The :badges cap is DERIVED from badges_max, not hardcoded, and must land in the
# @economy_caps hash the Ledger actually reads (YAML alone would be :bad_field).
class ConfigTest < Minitest::Test
  def test_badges_cap_is_derived_and_present_in_economy_caps
    cfg = PEMK::Config.new
    assert_equal 63, cfg.badges_max
    assert cfg.economy_caps.key?(:badges),
           "the Ledger reads @economy_caps -> :badges must be present or every badge frame is :bad_field"
    assert_equal((1 << 63) - 1, cfg.economy_caps[:badges])   # == signed-bigint max, fits the column exactly
    assert_equal((1 << cfg.badges_max) - 1, cfg.economy_caps[:badges]) # single source of truth
  end
end
