require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/encounter_mint"

# M4 Layer D D2 wild-encounter roller: picks a slot (species+level) by weight from the
# Layer A encounter tables and mints identity {pid, iv[6], shiny}. Pure (no DB). Uses an
# injected deterministic RNG for exact-output assertions + SecureRandom for a distribution
# smoke-test.
class EncounterMintTest < Minitest::Test
  # Minimal stand-in for WorldData#encounters(map_id).
  class FakeWorld
    def initialize(h); @h = h; end
    def encounters(map_id); @h[map_id]; end
  end

  # random_number(n) -> next queued value mod n (0 when exhausted).
  class SeqRng
    def initialize(vals); @vals = vals.dup; end
    def random_number(n); (@vals.shift || 0) % n; end
  end

  TABLE = {
    5 => { "0" => {
      "Land"  => { "step_chance" => 21, "slots" => [[40, "PIDGEY", 3, 5], [40, "RATTATA", 2, 4], [20, "PIKACHU", 5, 5]] },
      "Water" => { "step_chance" => 2,  "slots" => [[100, "MAGIKARP", 5, 10]] }
    } }
  }.freeze

  def world; FakeWorld.new(TABLE); end

  def test_table_slots_lookup
    m = PEMK::EncounterMint.new(world)
    assert_equal 3, m.table_slots(5, "Land").length
    assert_equal [[100, "MAGIKARP", 5, 10]], m.table_slots(5, "Water")
    assert_nil m.table_slots(5, "Cave")     # no such type
    assert_nil m.table_slots(99, "Land")    # unexported map
  end

  def test_legality
    m = PEMK::EncounterMint.new(world)
    assert_equal true,  m.legal?(5, "Land", "PIDGEY")
    assert_equal true,  m.legal?(5, "Land", :PIKACHU)      # symbol tolerated
    assert_equal false, m.legal?(5, "Land", "MEWTWO")      # not in the Land table
    assert_nil m.legal?(5, "Cave", "ZUBAT")               # no table -> unjudgeable
    assert_nil m.legal?(99, "Land", "PIDGEY")
  end

  def test_roll_is_deterministic_with_injected_rng
    # roll() draws: [slot-pick, level, pid, iv0..iv5, shiny]
    rng = SeqRng.new([0, 0, 12_345, 1, 2, 3, 4, 5, 6, 100])   # slot r=0 -> PIDGEY; level 3+0; pid; ivs; shiny 100<16=false
    r = PEMK::EncounterMint.new(world, rng: rng).roll(5, "Land")
    assert_equal "PIDGEY", r["species"]
    assert_equal 3, r["level"]
    assert_equal 12_345, r["pid"]
    assert_equal [1, 2, 3, 4, 5, 6], r["iv"]
    assert_equal false, r["shiny"]
  end

  def test_roll_weighted_pick_and_level_range
    # r=60 -> 60-40=20>=0, 20-40=-20<0 -> RATTATA (2nd slot); level range 2..4
    rng = SeqRng.new([60, 2, 0, 0, 0, 0, 0, 0, 0, 5])
    r = PEMK::EncounterMint.new(world, rng: rng).roll(5, "Land")
    assert_equal "RATTATA", r["species"]
    assert_equal 4, r["level"]              # 2 + (2 % 3)
  end

  def test_roll_shiny_flag
    shiny = PEMK::EncounterMint.new(world, rng: SeqRng.new([0, 0, 0, 0, 0, 0, 0, 0, 0, 15])).roll(5, "Land")
    assert_equal true, shiny["shiny"]       # 15 < 16
  end

  def test_roll_returns_nil_without_a_table
    m = PEMK::EncounterMint.new(world)
    assert_nil m.roll(99, "Land")
    assert_nil m.roll(5, "Cave")
  end

  def test_roll_distribution_smoke_with_securerandom
    m = PEMK::EncounterMint.new(world)   # real SecureRandom
    counts = Hash.new(0)
    3000.times do
      r = m.roll(5, "Land")
      counts[r["species"]] += 1
      assert_includes %w[PIDGEY RATTATA PIKACHU], r["species"]
      lo, hi = case r["species"]
               when "PIDGEY" then [3, 5]
               when "RATTATA" then [2, 4]
               else [5, 5]
               end
      assert_operator r["level"], :>=, lo
      assert_operator r["level"], :<=, hi
    end
    # weight 40/40/20 -> the two heavy slots each clearly out-appear the light one
    assert_operator counts["PIDGEY"], :>, counts["PIKACHU"]
    assert_operator counts["RATTATA"], :>, counts["PIKACHU"]
    assert_operator counts["PIKACHU"], :>, 0   # but it still appears
  end
end
