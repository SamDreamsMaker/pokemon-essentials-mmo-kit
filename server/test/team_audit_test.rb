require "minitest/autorun"
require "json"
require "tempfile"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/battle_data"
require "pemk/team_audit"

# M4 Layer D D1 team/set legality predicate: validates a client-reported full-stat team
# against the BattleData read model. Pure (no DB). Uses a small fixture with a 3-stage
# evolution line to exercise pre-evolution move inheritance.
class TeamAuditTest < Minitest::Test
  IVS = { "HP" => 31, "ATTACK" => 31, "DEFENSE" => 31, "SPECIAL_ATTACK" => 31, "SPECIAL_DEFENSE" => 31, "SPEED" => 31 }.freeze

  def self.sp(id, min_level, prev, level_up, tutor, egg)
    { "species" => id, "form" => 0, "types" => ["GRASS"], "base_exp" => 64, "growth_rate" => "Parabolic",
      "catch_rate" => 45, "abilities" => ["OVERGROW"], "hidden_abilities" => ["CHLOROPHYLL"],
      "base_stats" => { "HP" => 45 }, "evs" => {},
      "level_up_moves" => level_up.map { |m| [1, m] }, "tutor_moves" => tutor, "egg_moves" => egg,
      "prev_species" => prev, "minimum_level" => min_level }
  end

  FIX = {
    "schema_version" => 1,
    "caps"    => { "max_level" => 100, "iv_stat_limit" => 31, "ev_limit" => 510, "ev_stat_limit" => 252, "no_vitamin_ev_cap" => true },
    "natures" => { "ADAMANT" => [["ATTACK", 10], ["SPECIAL_ATTACK", -10]], "HARDY" => [] },
    "growth_rates" => { "Parabolic" => { "max_exp" => 1_059_860 } },
    "types"   => {},
    "abilities" => %w[OVERGROW CHLOROPHYLL LEVITATE],
    "items"   => {
      "LEFTOVERS"  => { "pocket" => 5, "is_ball" => false, "is_berry" => false, "is_machine" => false, "can_hold" => true, "move" => nil },
      "MASTER_BALL" => { "pocket" => 3, "is_ball" => true, "is_berry" => false, "is_machine" => false, "can_hold" => false, "move" => nil }
    },
    "moves"   => %w[TACKLE GROWL VINEWHIP RAZORLEAF PETALDANCE SOLARBEAM TOXIC CURSE EARTHQUAKE THUNDERSHOCK HYDROPUMP].each_with_object({}) { |id, h| h[id] = { "type" => "NORMAL", "category" => 0, "power" => 0, "accuracy" => 100, "pp" => 10, "priority" => 0, "target" => "NearOther", "function_code" => "None", "flags" => [], "effect_chance" => 0 } },
    "species" => {
      "BULBASAUR" => sp("BULBASAUR", 1, nil, %w[TACKLE GROWL VINEWHIP], %w[TOXIC], %w[CURSE]),
      "IVYSAUR"   => sp("IVYSAUR", 16, "BULBASAUR", %w[TACKLE VINEWHIP RAZORLEAF], [], []),
      "VENUSAUR"  => sp("VENUSAUR", 32, "IVYSAUR", %w[PETALDANCE], %w[SOLARBEAM], []),
      # A base form and its alt form, keyed by the FORM-specific export id. The wash
      # form learns Hydro Pump; the base form does not — so the client MUST report the
      # form-resolved id or an alt-form mon is judged against form-0 data (the bug the
      # TeamReport species_key fix prevents).
      "ROTOM"   => sp("ROTOM", 1, nil, %w[THUNDERSHOCK], [], []),
      "ROTOM_5" => sp("ROTOM_5", 1, nil, %w[THUNDERSHOCK HYDROPUMP], [], [])
    }
  }.freeze

  def setup
    @tmp = []
    @bd  = new_bd(FIX)
    @logs = []
    @audit = PEMK::TeamAudit.new(@bd, mode: :shadow, party_max: 6, logger: ->(m) { @logs << m })
  end

  def teardown
    @tmp.each { |f| f.close! rescue nil }
  end

  def new_bd(doc)
    f = Tempfile.new(["pemk_ta", ".json"]); f.write(JSON.generate(doc)); f.flush; @tmp << f
    PEMK::BattleData.new(f.path)
  end

  def mon(species, level: 50, ivs: IVS, evs: {}, moves: [], ability: "OVERGROW", nature: "ADAMANT", item: nil)
    { "species" => species, "level" => level, "ivs" => ivs, "evs" => evs,
      "moves" => moves, "ability" => ability, "nature" => nature, "item" => item }
  end

  # violations for slot 0 of a one-mon team
  def violations_of(m)
    r = @audit.check(1, [m])
    r[:mons].empty? ? [] : r[:mons][0][:violations]
  end

  def test_a_fully_legal_team_passes
    team = [mon("BULBASAUR", moves: %w[TACKLE VINEWHIP TOXIC CURSE], evs: { "HP" => 252, "SPECIAL_ATTACK" => 252, "SPEED" => 4 },
               ability: "OVERGROW", item: "LEFTOVERS")]
    r = @audit.check(1, team)
    assert r[:checked]
    assert r[:legal], r.inspect
    assert_empty r[:mons]
    assert_empty @logs
  end

  def test_absent_battle_data_is_unjudgeable
    bd = PEMK::BattleData.new(File.join(Dir.tmpdir, "pemk_absent_ta_#{Process.pid}.json"))
    audit = PEMK::TeamAudit.new(bd, mode: :on, party_max: 6)
    assert_equal({ checked: false }, audit.check(1, [mon("BULBASAUR")]))
  end

  def test_unknown_species
    assert_equal ["unknown_species:MISSINGNO"], violations_of(mon("MISSINGNO"))
  end

  def test_level_bounds
    assert_includes violations_of(mon("BULBASAUR", level: 0)),   "level_out_of_range:0"
    assert_includes violations_of(mon("BULBASAUR", level: 101)), "level_out_of_range:101"
    assert_includes violations_of(mon("BULBASAUR", level: "50")), "level_out_of_range:\"50\""
  end

  def test_below_minimum_level
    assert_includes violations_of(mon("VENUSAUR", level: 10, moves: %w[PETALDANCE])), "below_minimum_level:10<32"
  end

  # below_minimum_level is SOFT: a real event/gift can distribute an evolved mon below
  # its evolution level, so it is logged ("suspect") but does NOT make the team illegal.
  def test_below_minimum_level_is_soft_not_illegal
    r = @audit.check(1, [mon("VENUSAUR", level: 10, moves: %w[PETALDANCE])])
    assert r[:legal], "soft-only team must stay legal: #{r.inspect}"
    assert_includes r[:mons][0][:violations], "below_minimum_level:10<32"
    assert(@logs.any? { |m| m.include?("suspect suspicious team") }, @logs.inspect)
  end

  # A HARD violation (a move the species genuinely can't learn) does make it illegal,
  # and mixing a hard + soft violation stays illegal (the Burmy-Payback + low-level case).
  def test_hard_violation_makes_team_illegal
    refute @audit.check(1, [mon("BULBASAUR", moves: %w[EARTHQUAKE])])[:legal]
    mixed = @audit.check(1, [mon("VENUSAUR", level: 5, moves: %w[EARTHQUAKE])])   # below-min (soft) + illegal move (hard)
    refute mixed[:legal]
    assert(@logs.any? { |m| m.include?("illegal team") }, @logs.inspect)
  end

  def test_illegal_and_unknown_moves
    assert_includes violations_of(mon("BULBASAUR", moves: %w[EARTHQUAKE])), "illegal_move:EARTHQUAKE" # exists, not learnable
    assert_includes violations_of(mon("BULBASAUR", moves: %w[FOOBAR])),     "unknown_move:FOOBAR"     # not a move at all
  end

  def test_pre_evolution_move_inheritance_is_legal
    # VENUSAUR legally knows GROWL (BULBASAUR level-up), RAZORLEAF (IVYSAUR level-up),
    # TOXIC (BULBASAUR tutor), CURSE (BULBASAUR egg) via the family chain.
    v = violations_of(mon("VENUSAUR", moves: %w[GROWL RAZORLEAF TOXIC CURSE PETALDANCE SOLARBEAM]))
    assert_empty v, v.inspect
  end

  def test_ability_legality
    assert_includes violations_of(mon("BULBASAUR", ability: "LEVITATE")), "illegal_ability:LEVITATE"
    assert_empty violations_of(mon("BULBASAUR", ability: "CHLOROPHYLL", moves: %w[TACKLE])) # hidden ability is legal
  end

  def test_unknown_nature
    assert_includes violations_of(mon("BULBASAUR", nature: "NOTANATURE")), "unknown_nature:NOTANATURE"
  end

  def test_iv_bounds
    assert_includes violations_of(mon("BULBASAUR", ivs: IVS.merge("HP" => 32))), "iv_out_of_range:HP=32"
    assert_includes violations_of(mon("BULBASAUR", ivs: IVS.merge("SPEED" => -1))), "iv_out_of_range:SPEED=-1"
  end

  def test_ev_bounds_per_stat_and_total
    assert_includes violations_of(mon("BULBASAUR", evs: { "HP" => 253 })), "ev_out_of_range:HP=253"
    over_total = { "HP" => 252, "ATTACK" => 252, "DEFENSE" => 252 }   # sum 756 > 510
    assert_includes violations_of(mon("BULBASAUR", evs: over_total)), "ev_total_over:756>510"
  end

  def test_item_legality
    assert_includes violations_of(mon("BULBASAUR", item: "MASTER_BALL", moves: %w[TACKLE])), "unholdable_item:MASTER_BALL"
    assert_includes violations_of(mon("BULBASAUR", item: "NONEXISTENT", moves: %w[TACKLE])), "unknown_item:NONEXISTENT"
    assert_empty violations_of(mon("BULBASAUR", item: "LEFTOVERS", moves: %w[TACKLE]))
  end

  def test_party_too_large
    team = Array.new(7) { mon("BULBASAUR", moves: %w[TACKLE]) }
    r = @audit.check(1, team)
    refute r[:legal]
    assert_includes r[:team_violations], "party_too_large:7>6"
  end

  def test_mode_sets_the_log_label
    @audit.check(1, [mon("BULBASAUR", moves: %w[EARTHQUAKE])])
    assert(@logs.any? { |m| m.include?("WOULD-REJECT") }, @logs.inspect)

    on = PEMK::TeamAudit.new(@bd, mode: :on, party_max: 6, logger: ->(m) { @logs << m })
    on.check(1, [mon("BULBASAUR", moves: %w[EARTHQUAKE])])
    assert(@logs.any? { |m| m.include?("REJECT illegal") && !m.include?("WOULD-REJECT") }, @logs.inspect)
  end

  def test_not_an_object_mon
    assert_equal ["not_an_object"], violations_of("garbage")
  end

  # An alt form is judged against ITS OWN learnset (keyed by the form-specific id), and
  # the same move on the base-form key is illegal — the contract the client species_key
  # fix relies on.
  def test_form_specific_species_lookup
    assert_empty violations_of(mon("ROTOM_5", moves: %w[HYDROPUMP]))            # legal for the wash form
    assert_includes violations_of(mon("ROTOM", moves: %w[HYDROPUMP])), "illegal_move:HYDROPUMP"
  end

  # Over-large team: flagged once, and the per-mon scan is bounded to the legal prefix.
  def test_oversized_team_scan_is_bounded
    team = Array.new(50) { mon("BULBASAUR", moves: %w[EARTHQUAKE]) }   # every mon illegal
    r = @audit.check(1, team)
    assert_includes r[:team_violations], "party_too_large:50>6"
    assert_operator r[:mons].length, :<=, 6   # only the legal-size prefix is detailed
  end
end
