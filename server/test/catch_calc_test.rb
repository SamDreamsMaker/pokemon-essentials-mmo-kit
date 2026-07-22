require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"
require "pemk/catch_calc"

# M4 Layer D D3 capture adjudication: ports pbCaptureCalc exactly. Expected values below
# are HAND-COMPUTED from the engine formula (005_Battle_CatchAndStoreMixin.rb:206) so a
# drift in the port fails loudly. Pure (no DB); deterministic via an injected RNG.
class CatchCalcTest < Minitest::Test
  class SeqRng
    def initialize(vals); @vals = vals.dup; end
    def random_number(n); (@vals.shift || 0) % n; end
  end

  FIX = {
    "schema_version" => 1,
    "caps" => {}, "natures" => {}, "growth_rates" => {}, "types" => {}, "abilities" => [],
    "items" => {}, "moves" => {},
    "species" => {
      # base HP 40, catch rate 255 (a Spinarak-like common mon)
      "SPINARAK" => { "species" => "SPINARAK", "form" => 0, "base_stats" => { "HP" => 40 }, "catch_rate" => 255 },
      # base HP 106, catch rate 3 (a legendary-like)
      "LEGEND"   => { "species" => "LEGEND", "form" => 0, "base_stats" => { "HP" => 106 }, "catch_rate" => 3 },
      # Shedinja rule
      "SHEDINJA" => { "species" => "SHEDINJA", "form" => 0, "base_stats" => { "HP" => 1 }, "catch_rate" => 45 },
      # Ultra Beast (catch rules: non-Beast ball -> base/10)
      "UBSPEC"   => { "species" => "UBSPEC", "form" => 0, "base_stats" => { "HP" => 100 }, "catch_rate" => 45,
                      "flags" => ["UltraBeast"] }
    }
  }.freeze

  def setup
    @tmp = Tempfile.new(["pemk_cc", ".json"])
    @tmp.write(JSON.generate(FIX)); @tmp.flush
    @bd = PEMK::BattleData.new(@tmp.path)
  end

  def teardown
    @tmp.close! rescue nil
  end

  def calc(rng_vals = [0, 0, 0, 0])
    PEMK::CatchCalc.new(@bd, rng: SeqRng.new(rng_vals))
  end

  # --- totalhp: floor((2*base+iv)*level/100) + level + 10 ---------------------------
  def test_total_hp_from_base_iv_level
    # (2*40+31)*12/100 = 13 (floor); +12+10 = 35
    assert_equal 35, calc.total_hp("SPINARAK", 12, 31)
    # iv 0: 80*12/100 = 9; +22 = 31
    assert_equal 31, calc.total_hp("SPINARAK", 12, 0)
    assert_equal 1, calc.total_hp("SHEDINJA", 50, 31)   # base 1 -> always 1
    assert_nil calc.total_hp("MISSINGNO", 10, 0)
  end

  # --- the x/y shake path, hand-computed --------------------------------------------
  # SPINARAK lvl 12 iv31: a=35. Full HP (b=35), plain ball, rate 255, no status:
  #   x = floor(((105-70)*255)/105) = 85
  #   y = floor(65536 / (255/85)^0.1875) = floor(65536 / 3^0.1875) = 53335
  def test_four_successful_shakes_is_caught
    v = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE")
    assert_equal({ shakes: 4, caught: true, critical: false, total_hp: 35 }, v)
  end

  def test_first_shake_failure_is_zero_shakes
    # 60000 >= y(53335) -> first roll fails -> 0 shakes
    v = calc([60_000, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE")
    assert_equal 0, v[:shakes]
    refute v[:caught]
  end

  def test_break_after_two_shakes
    # two passes then a fail -> exactly 2 shakes (the sequential-break loop)
    v = calc([0, 0, 60_000, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE")
    assert_equal 2, v[:shakes]
    refute v[:caught]
  end

  def test_shake_threshold_boundary
    # roll == y-1 passes, roll == y fails (strict <)
    y = 53_335
    assert calc([y - 1, y - 1, y - 1, y - 1]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE")[:caught]
    assert_equal 0, calc([y, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE")[:shakes]
  end

  # --- unconditional + auto-catch ---------------------------------------------------
  def test_master_ball_is_unconditional
    v = calc([60_000] * 4).adjudicate("LEGEND", 70, 0, "MASTERBALL", 999, "NONE")
    assert_equal({ shakes: 4, caught: true, critical: false, total_hp: v[:total_hp] }, v)
  end

  def test_x_at_255_is_auto_catch
    # Ultra Ball (cap x2 -> 510) at b=1: a=35, x = floor((103*510)/105) = 500 >= 255
    v = calc([60_000] * 4).adjudicate("SPINARAK", 12, 31, "ULTRABALL", 1, "NONE", claimed_rate: 510)
    assert v[:caught]
    assert_equal 4, v[:shakes]
  end

  # --- status multiplier ------------------------------------------------------------
  def test_sleep_multiplies_2_5
    # x = floor(85 * 2.5) = 212 (< 255, still rolls); y = floor(65536/(255/212)^0.1875) = 63305
    v = calc([63_304, 63_304, 63_304, 63_304]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "SLEEP")
    assert v[:caught]
    v2 = calc([63_305, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "SLEEP")
    assert_equal 0, v2[:shakes]
  end

  def test_unknown_status_is_neutral
    # garbage status -> x stays 85 -> y 53337: 53338 fails
    v = calc([53_336, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "GARBAGE")
    assert_equal 0, v[:shakes]
  end

  # --- clamps (the anti-cheat envelope) ----------------------------------------------
  def test_claimed_rate_clamps_to_the_ball_cap
    # ULTRABALL cap = 255*2 = 510; a lying 60000 claim clamps to 510 -> same as honest 510
    lied   = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "ULTRABALL", 1, "NONE", claimed_rate: 60_000)
    honest = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "ULTRABALL", 1, "NONE", claimed_rate: 510)
    assert_equal honest, lied
  end

  def test_unknown_ball_caps_at_base_rate
    # unknown ball: cap = base 255; claim 9999 -> 255 -> same as plain full-HP (x=85, y=53335)
    v = calc([53_335, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "WEIRDBALL", 35, "NONE", claimed_rate: 9_999)
    assert_equal 0, v[:shakes]
  end

  def test_hp_current_clamps_to_server_total
    # a lying hp_current=0 (or negative) clamps to 1..a; 0 -> 1 gives the BEST case the
    # server allows; hp > a clamps down to a (full HP)
    low  = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 0, "NONE")
    one  = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 1, "NONE")
    assert_equal one, low
    over = calc([53_335, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 9_999, "NONE")
    assert_equal 0, over[:shakes]   # clamped to full HP -> y = 53335 -> 53335 fails
  end

  # x8 balls carry the engine's 255 ceiling on the MODIFIED rate: a base-255 species with
  # a claimed x8 Level Ball must NOT hit the x>=255 auto-catch at full HP (pre-fix it did).
  def test_level_ball_ceiling_255
    v = calc([60_000, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "LEVELBALL", 35, "NONE", claimed_rate: 2_040)
    assert_equal 0, v[:shakes]   # rate clamped to 255 -> x=85 -> first roll (60000 >= 53335) fails
    refute v[:caught]
  end

  # gen8: Dusk Ball is x3, not x3.5 — a 3.5-based claim clamps down to the x3 cap.
  def test_dusk_ball_cap_is_gen8_x3
    lied   = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "DUSKBALL", 1, "NONE", claimed_rate: 892)
    honest = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "DUSKBALL", 1, "NONE", claimed_rate: 765)
    assert_equal honest, lied
  end

  # Ultra Beast: any non-Beast ball caps at base/10 (engine's catch_rate /= 10), even if
  # the client claims the normal ball modifier; a Beast Ball keeps its x5.
  def test_ultra_beast_non_beast_ball_caps_at_tenth
    lied   = calc([0, 0, 0, 0]).adjudicate("UBSPEC", 50, 0, "ULTRABALL", 1, "NONE", claimed_rate: 90)
    honest = calc([0, 0, 0, 0]).adjudicate("UBSPEC", 50, 0, "ULTRABALL", 1, "NONE", claimed_rate: 4)
    assert_equal honest, lied
    beast  = calc([23_186, 0, 0, 0]).adjudicate("UBSPEC", 50, 0, "BEASTBALL", 1, "NONE", claimed_rate: 225)
    refute_nil beast   # x5 allowed with the Beast Ball (rate 225 used, not 4)
    assert_operator beast[:shakes], :>=, 1   # y(rate 225 at b=1) far exceeds 23186 -> first shake passes
  end

  # The engine carries the modified rate as a FLOAT (e.g. 45*1.5=67.5); a Numeric claim
  # must be used as-is, not discarded for the base rate.
  def test_float_claimed_rate_is_accepted
    # rate 67.5 -> x = floor((35*67.5)/105) = 22 -> y = 41395; roll 50000 fails.
    # (If the Float were discarded for base 255, x=85 -> y=53335 and 50000 would pass.)
    v = calc([50_000, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "GREATBALL", 35, "NONE", claimed_rate: 67.5)
    assert_equal 0, v[:shakes]
  end

  def test_heavy_ball_cap_is_additive_with_255_ceiling
    # LEGEND (base 3): HEAVYBALL cap = min(3+30, 255) = 33; claim 5000 -> 33
    # full HP a=228: x = floor((228*33)/684) = 11 -> y = 36350
    v = calc([36_349, 36_349, 36_349, 36_349]).adjudicate("LEGEND", 70, 0, "HEAVYBALL", 228, "NONE", claimed_rate: 5_000)
    assert v[:caught]
    v2 = calc([36_350, 0, 0, 0]).adjudicate("LEGEND", 70, 0, "HEAVYBALL", 228, "NONE", claimed_rate: 5_000)
    assert_equal 0, v2[:shakes]
    # base 255: the additive +30 clamps back to the engine's 255 ceiling (plain-ball odds)
    v3 = calc([53_335, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "HEAVYBALL", 35, "NONE", claimed_rate: 5_000)
    assert_equal 0, v3[:shakes]
  end

  # --- critical capture ---------------------------------------------------------------
  def test_critical_capture_single_roll
    # dex 700 -> mod 5, charm -> 10; c = 85*10/12 = 70 (int div)
    # rng: [crit_roll(256), shake_roll(65536)]
    win = calc([69, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE", dex_owned: 700, charm: true)
    assert_equal({ shakes: 4, caught: true, critical: true, total_hp: 35 }, win)
    lose = calc([69, 60_000]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE", dex_owned: 700, charm: true)
    assert_equal({ shakes: 0, caught: false, critical: true, total_hp: 35 }, lose)
    # crit roll misses (70 >= c) -> normal 4-shake path
    norm = calc([70, 0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE", dex_owned: 700, charm: true)
    refute norm[:critical]
    assert norm[:caught]
  end

  def test_no_dex_means_no_crit_roll
    # dex 0 -> c=0 -> the 4 shake rolls consume the FIRST rng values (no crit draw)
    v = calc([0, 0, 0, 0]).adjudicate("SPINARAK", 12, 31, "POKEBALL", 35, "NONE", dex_owned: 0)
    assert v[:caught]
    refute v[:critical]
  end

  # --- low catch-rate legendary hand-check --------------------------------------------
  def test_legendary_full_hp_odds
    # LEGEND lvl 70 iv0: a = floor(212*70/100)+70+10 = 148+80 = 228
    # x = floor((3*228-2*228)*3 / (3*228)) = floor(228*3/684) = 1 -> y = floor(65536/255^0.1875) = 23189
    v = calc([23_186, 23_186, 23_186, 23_186]).adjudicate("LEGEND", 70, 0, "POKEBALL", 228, "NONE")
    assert v[:caught]
    v2 = calc([23_187, 0, 0, 0]).adjudicate("LEGEND", 70, 0, "POKEBALL", 228, "NONE")
    assert_equal 0, v2[:shakes]
  end

  def test_unknown_species_is_unjudgeable
    assert_nil calc.adjudicate("MISSINGNO", 10, 0, "POKEBALL", 20, "NONE")
  end
end
