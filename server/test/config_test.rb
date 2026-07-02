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

  def test_inventory_caps_are_present_and_fail_fast
    cfg = PEMK::Config.new
    assert_equal({ per_item: 99_999, distinct: 2000, total: 10_000_000 }, cfg.inventory_caps)
  end

  def test_monster_caps_are_present_and_fail_fast
    cfg = PEMK::Config.new
    assert_equal({ uid_req_max: 64, party_max: 6, level_max: 100 }, cfg.monster_caps)
  end
end
