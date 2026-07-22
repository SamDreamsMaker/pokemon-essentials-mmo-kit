require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"
require "pemk/reward_calc"

# M4 Layer D D4: the closed-form reward envelopes. Expected exp values are computed
# INDEPENDENTLY from the gen-8 scaled engine formula (a/5 int-div, levelAdjust at
# gainer level 1, floor+1, x1.7 -> x3/2 -> x3/2 with engine rounding).
class RewardCalcTest < Minitest::Test
  FIX = {
    "schema_version" => 1,
    "caps" => { "max_level" => 100 }, "natures" => {}, "types" => {}, "abilities" => [],
    "items" => {}, "moves" => {},
    "growth_rates" => {
      # tiny fake curve for jump tests: exp to BE at level 1..5
      "Toy" => { "max_exp" => 100, "curve" => [0, 10, 30, 60, 100] },
      "NoCurve" => { "max_exp" => 1_000 }   # an OLD export without the curve
    },
    "species" => {
      "HOOTHOOT" => { "species" => "HOOTHOOT", "form" => 0, "base_stats" => { "HP" => 60 },
                      "base_exp" => 64, "growth_rate" => "Toy", "catch_rate" => 255 },
      "MEWTWOISH" => { "species" => "MEWTWOISH", "form" => 0, "base_stats" => { "HP" => 106 },
                       "base_exp" => 255, "growth_rate" => "Toy", "catch_rate" => 3 },
      "NOEXP" => { "species" => "NOEXP", "form" => 0, "base_stats" => { "HP" => 10 } }
    }
  }.freeze

  def setup
    @tmp = Tempfile.new(["pemk_rc", ".json"])
    @tmp.write(JSON.generate(FIX)); @tmp.flush
    @calc = PEMK::RewardCalc.new(PEMK::BattleData.new(@tmp.path))
  end

  def teardown
    @tmp.close! rescue nil
  end

  # --- exp envelope (independently computed engine values) ---------------------------
  def test_max_exp_per_mon_hand_checked
    assert_equal 1_197,  @calc.max_exp_per_mon("HOOTHOOT", 10)     # base 64, lvl 10
    assert_equal 24_103, @calc.max_exp_per_mon("HOOTHOOT", 100)    # base 64, lvl 100
    assert_equal 42_594, @calc.max_exp_per_mon("MEWTWOISH", 50)    # base 255, lvl 50
  end

  def test_max_exp_per_foe_is_six_gainers
    assert_equal 1_197 * 6, @calc.max_exp_per_foe("HOOTHOOT", 10)
  end

  def test_unknown_species_or_missing_base_exp_is_unjudgeable
    assert_nil @calc.max_exp_per_mon("MISSINGNO", 10)
    assert_nil @calc.max_exp_per_mon("NOEXP", 10)
  end

  def test_foe_level_is_clamped
    assert_equal @calc.max_exp_per_mon("HOOTHOOT", 100), @calc.max_exp_per_mon("HOOTHOOT", 9_999)
    assert_equal @calc.max_exp_per_mon("HOOTHOOT", 1),   @calc.max_exp_per_mon("HOOTHOOT", -5)
  end

  # --- level-jump minimum exp ---------------------------------------------------------
  def test_min_exp_for_jump
    # at level 2 exp < curve(3)=30; to BE level 4 needs curve(4)=60 -> min gained = 60-30+1
    assert_equal 31, @calc.min_exp_for_jump("Toy", 2, 4)
    assert_equal 1,  @calc.min_exp_for_jump("Toy", 2, 3)   # one point can tip it
    assert_equal 0,  @calc.min_exp_for_jump("Toy", 4, 4)   # no jump
    assert_equal 0,  @calc.min_exp_for_jump("Toy", 4, 2)   # level DOWN (never negative)
  end

  def test_min_exp_for_jump_unjudgeable_without_curve
    assert_nil @calc.min_exp_for_jump("NoCurve", 2, 4)     # old export: no curve
    assert_nil @calc.min_exp_for_jump("Nope", 2, 4)        # unknown rate
    assert_nil @calc.min_exp_for_jump("Toy", 5, 9)         # beyond the curve -> unjudgeable
    assert_nil @calc.min_exp_for_jump("Toy", nil, 4)
  end

  # --- money envelopes derived from exported max_level -------------------------------
  def test_money_envelopes_scale_with_max_level
    assert_equal 100, @calc.max_level               # from caps.max_level in the fixture
    assert_equal 12_000,  @calc.wild_money_loss_max # 100 * 120 (blackout badge cap)
    assert_equal 100_000, @calc.wild_money_gain_max # 100 * 1000 (generous Pay Day)
  end
end
