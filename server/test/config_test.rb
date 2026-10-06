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

  # M4 Layer D D3: catch adjudication mode, off/shadow/on tri-state, default off.
  def test_battle_enforce_catches_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_CATCHES")
    assert_equal :off,    PEMK::Config.new(env: env).battle_enforce_catches
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_CATCHES" => "shadow")).battle_enforce_catches
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_CATCHES" => "ON")).battle_enforce_catches
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_CATCHES" => "junk")).battle_enforce_catches
  end

  # M4 Layer D D4: reward detection mode, off/shadow/on tri-state, default off.
  def test_battle_enforce_rewards_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_REWARDS")
    assert_equal :off,    PEMK::Config.new(env: env).battle_enforce_rewards
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_REWARDS" => "shadow")).battle_enforce_rewards
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_REWARDS" => "ON")).battle_enforce_rewards
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_REWARDS" => "junk")).battle_enforce_rewards
  end

  # M4 Layer D D6: per-mon EXP authority, off/shadow/on tri-state, default off.
  def test_battle_enforce_exp_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_EXP")
    assert_equal :off,    PEMK::Config.new(env: env).battle_enforce_exp
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_EXP" => "shadow")).battle_enforce_exp
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_EXP" => "ON")).battle_enforce_exp
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_EXP" => "junk")).battle_enforce_exp
  end

  # M4 Layer D D7 part 1: the deterministic battle seam, off/shadow/on, default off.
  def test_battle_enforce_rng_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_RNG")
    assert_equal :off,    PEMK::Config.new(env: env).battle_enforce_rng
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RNG" => "shadow")).battle_enforce_rng
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RNG" => "ON")).battle_enforce_rng
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RNG" => "junk")).battle_enforce_rng
  end

  # M4 Layer D D7 part 3: corpus retention days — matched records only; 0 = keep forever.
  def test_corpus_retention_days_defaults_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_CORPUS_RETENTION_DAYS")
    assert_equal 30, PEMK::Config.new(env: env).corpus_retention_days
    assert_equal 7,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_CORPUS_RETENTION_DAYS" => "7")).corpus_retention_days
    assert_equal 0,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_CORPUS_RETENTION_DAYS" => "0")).corpus_retention_days
    assert_equal 30, PEMK::Config.new(env: ENV.to_h.merge("PEMK_CORPUS_RETENTION_DAYS" => "junk")).corpus_retention_days
  end

  # M4 Layer D D8: resim enforcement — its OWN flag (operator contract), default off.
  def test_battle_enforce_resim_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BATTLE_ENFORCE_RESIM")
    assert_equal :off,    PEMK::Config.new(env: env).battle_enforce_resim
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RESIM" => "shadow")).battle_enforce_resim
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RESIM" => "ON")).battle_enforce_resim
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BATTLE_ENFORCE_RESIM" => "junk")).battle_enforce_resim
  end

  def test_resim_min_strikes_defaults_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_RESIM_MIN_STRIKES")
    assert_equal 2, PEMK::Config.new(env: env).resim_min_strikes
    assert_equal 1, PEMK::Config.new(env: ENV.to_h.merge("PEMK_RESIM_MIN_STRIKES" => "1")).resim_min_strikes
    assert_equal 2, PEMK::Config.new(env: ENV.to_h.merge("PEMK_RESIM_MIN_STRIKES" => "0")).resim_min_strikes   # 0 invalid -> default
    assert_equal 2, PEMK::Config.new(env: ENV.to_h.merge("PEMK_RESIM_MIN_STRIKES" => "junk")).resim_min_strikes
  end

  # Audit item 4: the switches/variables shadow, off/shadow/on, default off.
  def test_flag_state_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_FLAG_STATE")
    assert_equal :off,    PEMK::Config.new(env: env).flag_state
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_FLAG_STATE" => "shadow")).flag_state
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_FLAG_STATE" => "ON")).flag_state
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_FLAG_STATE" => "junk")).flag_state
  end

  # M4 Layer D D5: anomaly detection, binary on/off, default off.
  def test_anomaly_detection_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_ANOMALY_DETECTION")
    refute PEMK::Config.new(env: env).anomaly_detection
    assert_equal true,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_ANOMALY_DETECTION" => "ON")).anomaly_detection
    assert_equal false, PEMK::Config.new(env: ENV.to_h.merge("PEMK_ANOMALY_DETECTION" => "junk")).anomaly_detection
  end

  # Badge authority: off/shadow/on, default off.
  def test_badge_authority_defaults_off_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BADGE_AUTHORITY")
    assert_equal :off,    PEMK::Config.new(env: env).badge_authority
    assert_equal :shadow, PEMK::Config.new(env: ENV.to_h.merge("PEMK_BADGE_AUTHORITY" => "shadow")).badge_authority
    assert_equal :on,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_BADGE_AUTHORITY" => " ON ")).badge_authority
    assert_equal :off,    PEMK::Config.new(env: ENV.to_h.merge("PEMK_BADGE_AUTHORITY" => "junk")).badge_authority
  end

  # The badge writes the operator says are not the game's: none by default.
  def test_badge_ignore_defaults_empty_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_BADGE_IGNORE")
    assert_equal [], PEMK::Config.new(env: env).badge_ignore
    list = PEMK::Config.new(env: ENV.to_h.merge("PEMK_BADGE_IGNORE" => " 3:7, CE:12,,Plugins/My Game/x.rb:40 ,3:7")).badge_ignore
    assert_equal ["3:7", "ce:12", "Plugins/My Game/x.rb:40"], list
    assert list.frozen?
  end

  # Debug mode on the clients: deny by default (a closed cheat path), junk never looser.
  def test_client_debug_defaults_deny_and_reads_env
    env = ENV.to_h
    env.delete("PEMK_CLIENT_DEBUG")
    assert_equal :deny,      PEMK::Config.new(env: env).client_debug
    assert_equal :autopilot, PEMK::Config.new(env: ENV.to_h.merge("PEMK_CLIENT_DEBUG" => "autopilot")).client_debug
    assert_equal :allow,     PEMK::Config.new(env: ENV.to_h.merge("PEMK_CLIENT_DEBUG" => " ALLOW ")).client_debug
    assert_equal :deny,      PEMK::Config.new(env: ENV.to_h.merge("PEMK_CLIENT_DEBUG" => "on")).client_debug
  end

  # Presence v2: on by default, off only when asked.
  def test_presence_dedup_defaults_on
    env = ENV.to_h
    env.delete("PEMK_PRESENCE_DEDUP")
    assert_equal true,  PEMK::Config.new(env: env).presence_dedup
    assert_equal false, PEMK::Config.new(env: ENV.to_h.merge("PEMK_PRESENCE_DEDUP" => " OFF ")).presence_dedup
    assert_equal true,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_PRESENCE_DEDUP" => "junk")).presence_dedup
  end

  # An abuse fix: on unless said off.
  def test_flood_guard_defaults_on
    env = ENV.to_h
    env.delete("PEMK_FLOOD_GUARD")
    assert_equal true,  PEMK::Config.new(env: env).flood_guard
    assert_equal false, PEMK::Config.new(env: ENV.to_h.merge("PEMK_FLOOD_GUARD" => " Off ")).flood_guard
    assert_equal true,  PEMK::Config.new(env: ENV.to_h.merge("PEMK_FLOOD_GUARD" => "junk")).flood_guard
  end
end
