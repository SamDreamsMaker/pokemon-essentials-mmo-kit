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
    assert_equal({ uid_req_max: 64, party_max: 6, level_max: 100, trade_max: 1 }, cfg.monster_caps)
  end

  # M4 Layer B enforcement mode: opt-in via PEMK_POS_ENFORCE, default :off, unknown -> :off.
  def test_position_enforcement_defaults_off
    env = ENV.to_h
    env.delete("PEMK_POS_ENFORCE")
    assert_equal :off, PEMK::Config.new(env: env).position_enforcement
  end

  def test_position_enforcement_reads_env
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_POS_ENFORCE" => "shadow")).position_enforcement
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_POS_ENFORCE" => "ON")).position_enforcement
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_POS_ENFORCE" => "garbage")).position_enforcement
  end

  # M4 Layer C: the DEV-ONLY pickup reset gate. Default off (prod-safe), only "on" enables it.
  def test_pickup_reset_allowed_defaults_off
    env = ENV.to_h
    env.delete("PEMK_ALLOW_PICKUP_RESET")
    refute PEMK::Config.new(env: env).pickup_reset_allowed
  end

  def test_pickup_reset_allowed_reads_env
    assert_equal true,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_ALLOW_PICKUP_RESET" => "ON")).pickup_reset_allowed
    assert_equal false, PEMK::Config.new(env: ENV.to_h.merge("PEMK_ALLOW_PICKUP_RESET" => "garbage")).pickup_reset_allowed
  end

  # M4 Layer D D1: team-legality enforcement mode, off/shadow/on tri-state, default off.
  def test_battle_enforce_teams_defaults_off
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_TEAMS")
    assert_equal :off, PEMK::Config.new(env: env).battle_enforce_teams
  end

  def test_battle_enforce_teams_reads_env
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_TEAMS" => "shadow")).battle_enforce_teams
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_TEAMS" => "ON")).battle_enforce_teams
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_TEAMS" => "garbage")).battle_enforce_teams
  end

  # M4 Layer D D2: encounter enforcement mode, off/shadow/on tri-state, default off.
  def test_battle_enforce_encounters_defaults_off
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_ENCOUNTERS")
    assert_equal :off, PEMK::Config.new(env: env).battle_enforce_encounters
  end

  def test_battle_enforce_encounters_reads_env
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "shadow")).battle_enforce_encounters
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "ON")).battle_enforce_encounters
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "nope")).battle_enforce_encounters
  end
end
