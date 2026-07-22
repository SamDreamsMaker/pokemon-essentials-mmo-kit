require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"
require "pemk/reward_calc"
require "pemk/reward_audit"

# M4 Layer D D4: the per-account reward window (battle -> exp/money budgets, consumed by
# level jumps + money deltas). Pure (no DB); a fixed `now` drives TTL deterministically.
class RewardAuditTest < Minitest::Test
  FIX = {
    "schema_version" => 1, "caps" => { "max_level" => 100 }, "natures" => {}, "types" => {},
    "abilities" => [], "items" => {}, "moves" => {},
    "growth_rates" => { "Toy" => { "max_exp" => 100_000, "curve" => (1..100).map { |n| n * 100 } } },
    "species" => {
      "HOOTHOOT" => { "species" => "HOOTHOOT", "form" => 0, "base_stats" => { "HP" => 60 },
                      "base_exp" => 64, "growth_rate" => "Toy" }
    }
  }.freeze

  def setup
    @tmp = Tempfile.new(["pemk_ra", ".json"]); @tmp.write(JSON.generate(FIX)); @tmp.flush
    @bd  = PEMK::BattleData.new(@tmp.path)
    @ra  = PEMK::RewardAudit.new(PEMK::RewardCalc.new(@bd), @bd)
    @t   = Time.now
  end

  def teardown
    @tmp.close! rescue nil
  end

  def foe(level = 10); { species: "HOOTHOOT", level: level }; end

  # --- money attribution --------------------------------------------------------------
  def test_money_gain_within_budget_is_attributed
    @ra.record_battle(1, [foe], 1, now: @t)              # win -> gain budget = 100_000
    reason, suspect = @ra.note_money(1, 500, now: @t)
    assert_equal "battle:1", reason
    refute suspect
  end

  def test_money_gain_over_budget_is_suspect_but_reason_stays_clean
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, suspect = @ra.note_money(1, 999_999, now: @t)
    assert_equal "battle:1", reason   # ledger stays clean-attributed, never "battle_suspect"
    assert suspect                    # the suspicion is a flag the caller LOGS
  end

  # A spend AFTER a win (win opens gain budget, loss=0) must NOT be flagged suspect and
  # must not pollute the ledger — it's a normal "won a little, bought a Potion".
  def test_spend_after_a_win_is_not_suspect
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, suspect = @ra.note_money(1, -300, now: @t)
    assert_equal "unattributed", reason
    refute suspect
  end

  def test_money_without_a_window_is_unattributed
    reason, suspect = @ra.note_money(1, 5_000, now: @t)  # a shop purchase, no battle
    assert_equal "unattributed", reason
    refute suspect
  end

  def test_loss_within_blackout_cap_is_attributed
    @ra.record_battle(1, [foe], 2, now: @t)              # lost -> loss budget = 12_000
    reason, suspect = @ra.note_money(1, -8_000, now: @t)
    assert_equal "battle:1", reason
    refute suspect
  end

  def test_loss_over_cap_is_not_suspect_just_unattributed
    @ra.record_battle(1, [foe], 2, now: @t)              # loss budget = 12_000
    reason, suspect = @ra.note_money(1, -50_000, now: @t) # a big purchase, bigger than blackout cap
    assert_equal "unattributed", reason                  # a decrease is never a reward cheat
    refute suspect
  end

  def test_gain_budget_is_consumed
    @ra.record_battle(1, [foe], 1, now: @t)
    100.times { assert_equal "battle:1", @ra.note_money(1, 1_000, now: @t)[0] }  # 100k exactly
    reason, suspect = @ra.note_money(1, 1, now: @t)                              # now empty
    assert_equal "battle:1", reason   # still attributed to the window
    assert suspect                    # ... but over budget -> flagged
  end

  def test_windows_stack_within_ttl
    @ra.record_battle(1, [foe], 1, now: @t)
    w = @ra.record_battle(1, [foe], 1, now: @t + 5)      # same window, budgets add
    assert_equal 1, w[:id]
    assert_equal 200_000, w[:gain]
  end

  def test_window_expires_after_ttl
    @ra.record_battle(1, [foe], 1, now: @t)
    reason, = @ra.note_money(1, 100, now: @t + 91)        # TTL 90s passed
    assert_equal "unattributed", reason
  end

  # --- level-jump exp check -----------------------------------------------------------
  def test_level_jump_within_exp_budget_ok
    @ra.record_battle(1, [foe(10)], 1, now: @t)           # exp budget = 1197*6 = 7182
    # curve is n*100: level 5->6 needs curve(6)-curve(5+1)... wait, old=5 -> ceil=curve(6)=600,
    # new=6 -> target=600 -> min = 600-600+1 = 1. Small jump, well within budget.
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 5, 6]], now: @t)
    refute suspect
  end

  def test_impossible_level_jump_is_suspect
    @ra.record_battle(1, [foe(10)], 1, now: @t)           # budget 7182
    # 1 -> 90: target curve(90)=9000, ceil curve(2)=200 -> min 8801 > 7182 -> suspect
    suspect, detail = @ra.check_levels(1, [["HOOTHOOT", 1, 90]], now: @t)
    assert suspect
    assert_includes detail, "needs >="
  end

  def test_level_jump_without_a_window_is_suspect_if_any_exp_needed
    # no battle recorded -> budget 0; any real jump exceeds it
    suspect, = @ra.check_levels(1, [["HOOTHOOT", 1, 5]], now: @t)
    assert suspect
  end

  def test_no_jump_is_never_suspect
    suspect, detail = @ra.check_levels(1, [["HOOTHOOT", 10, 10]], now: @t)
    refute suspect
    assert_nil detail
  end

  def test_unjudgeable_jump_is_skipped_not_suspect
    # unknown species -> that jump is skipped; with no other need, not suspect
    suspect, = @ra.check_levels(1, [["MISSINGNO", 1, 50]], now: @t)
    refute suspect
  end
end
