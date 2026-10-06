require "minitest/autorun"
require "rbconfig"

# D2: only the encounter table's own roll is minted (on) or reported (shadow) - driven
# through the engine's own code: the step encounter (pbBattleOnStepTaken), the roamer and
# Poke Radar handlers, WildBattle.start and generate_foes, pbGenerateWildPokemon. A roll a
# handler writes to - even with the values it held - is the game's, like an event's battle.
class EncounterFidelityPluginTest < Minitest::Test
  ROOT    = File.expand_path("../..", __dir__)
  PLUGIN  = File.join(ROOT, "Plugins/PEMK/009_BattleData/004_Encounter.rb")
  SCRIPTS = File.join(ROOT, "Data/Scripts")
  ENGINE  = ["003_Game processing/005_Event_Handlers.rb", "003_Game processing/006_Event_HandlerCollections.rb",
             "012_Overworld/002_Battle triggering/003_Overworld_WildEncounters.rb",
             "012_Overworld/002_Battle triggering/001_Overworld_BattleStarting.rb",
             "012_Overworld/002_Battle triggering/005_Overworld_RoamingPokemon.rb",
             "013_Items/005_Item_PokeRadar.rb", "012_Overworld/001_Overworld.rb"].freeze

  HARNESS = <<~'RUBY'
    require "ostruct"
    $log = []; $mints = []; $sent = []; $battles = []
    def rand(x = nil)
      return 99 if x == 100
      return x.first if x.is_a?(Range)

      0
    end
    module Settings
      ROAMING_SPECIES = [[:RAIKOU, 50, 0, 0, nil, { 31 => [31] }]]
      MORE_ABILITIES_AFFECT_WILD_ENCOUNTERS = true
      HIGHER_SHINY_CHANCES_WITH_NUMBER_BATTLED = false
      POKERUS_CHANCE = 0
    end
    module GameData
      class Species
        Data = Struct.new(:id)
        def self.get(s) = Data.new(s.to_sym)
        def self.exists?(_s) = true
      end
      class EncounterType
        Data = Struct.new(:type)
        def self.exists?(_t) = true
        def self.get(t) = Data.new({ Land: :land, Cave: :cave }.fetch(t, :land))
      end
      class GrowthRate; def self.max_level = 100; end
    end
    class Pokemon
      attr_accessor :species, :level, :personalID, :shiny, :super_shiny, :nature, :item, :form, :iv
      def initialize(species, level, _owner = nil, _moves = true)
        @species = species.to_s.sub(/_\d+\z/, "").to_sym   # a form's id names its species
        @level = level
        @personalID = 1
        @iv = {}
        @form = 0
      end
      def species_data = GameData::Species.get(@species)
      def wildHoldItems = [[], [], []]
      def shiny? = @shiny == true
      def givePokerus; end
      def singleGendered? = true
      def form_simple=(v); @form = v; end
      def calc_stats; end
      def reset_moves; end
    end
    module MultipleForms; def self.hasFunction?(*) = false; end
    module PEMK
      def self.log(m) = $log << m
      def self.enabled? = true
      def self.self_id = 7
      def self.client = OpenStruct.new(connected?: true)
      def self.send_message(h) = $sent << h
      module Config; ENCOUNTER_GRANT_TIMEOUT = 1; end
      module Reward; def self.note_foe(_p); end; end
      module BattleRng; def self.note_grant(*); end; end
    end
    module ItemHandlers
      class Stub; def add(*); end; end
      UseInField = Stub.new
      UseFromBag = Stub.new
    end
    S = ARGV[1]
    ARGV[3].split("|").each { |f| load File.join(S, f) }
    def pbPokeRadarHighlightGrass(*); end
    def setBattleRule(*); end
    def pbGetCurrentRegion(*) = 0
    class WildBattle
      def self.start_core(*foes)
        $battles << foes.map { |p| [p.species, p.level, p.shiny == true] }
        1
      end
    end
    load ARGV[0]
    module PEMK
      module Encounter
        def self.request(map, type)
          $mints << [map, type.to_s]
          $nested&.call
          { type: :encounter_grant, species: "ZUBAT", level: 9, pid: 4242 + $mints.size, iv: [1, 2, 3, 4, 5, 6], shiny: false }
        end
      end
    end

    $player = OpenStruct.new(able_pokemon_count: 1, first_pokemon: nil)
    $bag = Object.new
    def $bag.has?(_item) = false
    $PokemonGlobal = OpenStruct.new(roamedAlready: true, roamPokemon: [], roamPokemonCaught: [], roamPosition: { 0 => 31 }, encounter_version: 0)
    $PokemonMap = OpenStruct.new
    $stats = OpenStruct.new(poke_radar_longest_chain: 0)
    $game_temp = OpenStruct.new
    $game_map = OpenStruct.new(map_id: 31, name: "Route", metadata: nil)
    $game_player = OpenStruct.new(x: 5, y: 5)
    $allow = true
    $double = false
    $PokemonEncounters = PokemonEncounters.new
    $PokemonEncounters.instance_variable_set(:@encounter_tables, { Land: [[100, :PIDGEY, 3, 3]] })
    class << $PokemonEncounters
      def encounter_possible_here? = true
      def encounter_type = :Land
      def encounter_triggered?(*) = true
      def allow_encounter?(*) = $allow
      def have_double_wild_battle? = $double
    end
    def table(*slots) = $PokemonEncounters.instance_variable_set(:@encounter_tables, { Land: slots })
    def rolls = PEMK::Encounter.instance_variable_get(:@rolls)

    PEMK::Encounter.adopt_mode("on")
    out = {}
    case ARGV[2]
    when "plain"
      pbBattleOnStepTaken(false)
      out[:granted] = $battles.last && PEMK::Encounter.granted?(OpenStruct.new(personalID: 4243))
      out[:local_granted] = PEMK::Encounter.granted?(Pokemon.new(:PIDGEY, 3))
    when "double"
      $double = true
      pbBattleOnStepTaken(false)
    when "nested"                                   # an event's battle generated while the first mint waits
      $double = true
      $nested = lambda do
        $nested = nil
        WildBattle.generate_foes(:PIDGEY, 4)
      end
      pbBattleOnStepTaken(false)
    when "roamer"
      $PokemonGlobal.roamedAlready = false
      pbBattleOnStepTaken(false)
    when "roamer_same"                              # the roamer is what the table rolled
      table([100, :RAIKOU, 50, 50])
      $PokemonGlobal.roamedAlready = false
      pbBattleOnStepTaken(false)
    when "radar_same"                               # the chain goes on with the very roll's values
      $game_temp.encounter_type = :Land
      $game_temp.poke_radar_data = [:PIDGEY, 3, 5, [[5, 5, 0, 2]]]
      pbBattleOnStepTaken(false)
    when "radar_rarer"
      PEMK::Encounter.adopt_mode("on")
      $PokemonEncounters.choose_wild_pokemon(:Land, 2)
      out[:rolls] = rolls.size
    when "stale"                                    # a roll a Repel turned away, then an event's battle
      $allow = false
      pbBattleOnStepTaken(false)
      out[:type] = $game_temp.encounter_type
      WildBattle.start(:KECLEON, 30)
      out[:stray] = $log.grep(/outside a wild battle's start/).size
    when "bounded"
      $allow = false
      20.times { pbBattleOnStepTaken(false) }
      out[:rolls] = rolls.size
      PEMK::Encounter.reset
      PEMK::Encounter.adopt_mode("off")
      pbBattleOnStepTaken(false)
      out[:off_rolls] = rolls.size
    when "shadow"
      PEMK::Encounter.adopt_mode("shadow")
      table([100, :SHELLOS_1, 20, 20])
      pbBattleOnStepTaken(false)
      $game_temp.encounter_type = :Land
      WildBattle.start(:KECLEON, 30)
    when "off"
      PEMK::Encounter.adopt_mode("off")
      pbBattleOnStepTaken(false)
    when "sweet_scent"                              # pbEncounter, two rolls of the table
      $double = true
      pbEncounter(:Land, false)
    when "radar_break"                              # a chain broken by a roll that already differs: no write
      table([50, :PIDGEY, 3, 3], [50, :RATTATA, 3, 3])
      $game_temp.encounter_type = :Land
      $game_temp.poke_radar_data = [:PIDGEY, 3, 5, [[5, 5, 0, 0]]]
      pbBattleOnStepTaken(false)
    when "stray"                                    # a plugin's own encounter, outside a battle's start
      stray = -> { $log.grep(/outside a wild battle's start/).size }
      PEMK::Encounter.adopt_mode("off")
      $game_temp.encounter_type = :Land
      pbGenerateWildPokemon(:PIDGEY, 3)
      out[:off] = stray.call
      PEMK::Encounter.adopt_mode("on")
      $game_temp.encounter_type = nil
      pbGenerateWildPokemon(:PIDGEY, 3)             # no encounter under way
      out[:untyped] = stray.call
      $game_temp.encounter_type = :Land
      pbGenerateWildPokemon(:PIDGEY, 3)
      pbGenerateWildPokemon(:PIDGEY, 3)
      out[:stray] = stray.call
    when "direct_write"                             # changed outside any handler, before the battle
      roll = $PokemonEncounters.choose_wild_pokemon(:Land)
      roll[0] = :MEW
      WildBattle.start(roll)
    when "twice"                                    # a roll mints one battle
      roll = $PokemonEncounters.choose_wild_pokemon(:Land)
      WildBattle.start(roll)
      WildBattle.start(roll)
    when "plugin_roll"                              # a plugin's own table roll: the roll's type, not the step's
      $game_temp.encounter_type = nil
      WildBattle.start($PokemonEncounters.choose_wild_pokemon(:Land))
    when "grants"
      20.times { |i| PEMK::Encounter.build_from_grant({ species: "ZUBAT", level: 9, pid: 100 + i }) }
      out[:first] = PEMK::Encounter.granted?(OpenStruct.new(personalID: 100))
      out[:last] = PEMK::Encounter.granted?(OpenStruct.new(personalID: 119))
      out[:kept] = PEMK::Encounter.instance_variable_get(:@granted).size
    when "seams"
      class PokemonEncounters
        alias later_choose choose_wild_pokemon
        def choose_wild_pokemon(type, rolls = 1) = later_choose(type, rolls).dup
      end
      PEMK::Encounter.adopt_mode("on")
      PEMK::Encounter.adopt_mode("on")
      pbBattleOnStepTaken(false)
    end
    out[:mints] = $mints
    out[:battles] = $battles
    out[:reports] = $sent.select { |h| h[:type] == :encounter_report }.map { |h| [h[:enctype], h[:species], h[:level]] }
    out[:said] = $log.grep(/redefines/)
    print out.inspect
  RUBY

  def run_case(name)
    out = IO.popen([RbConfig.ruby, "-W0", "-e", HARNESS, PLUGIN, SCRIPTS, name, ENGINE.join("|")], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    eval(out) # rubocop:disable Security/Eval
  end

  def test_the_tables_roll_is_minted
    r = run_case("plain")
    assert_equal [[31, "Land"]], r[:mints]
    assert_equal [[[:ZUBAT, 9, false]]], r[:battles], "the server's Pokemon"
    assert r[:granted], "a foe built from a grant can be judged at a catch..."
    refute r[:local_granted], "... a local one cannot"
    assert_empty r[:said], "no seam was redefined"
  end

  def test_a_double_battle_mints_both_even_with_a_battle_generated_meanwhile
    assert_equal [[31, "Land"], [31, "Land"]], run_case("double")[:mints]
    r = run_case("nested")
    assert_equal [[31, "Land"], [31, "Land"]], r[:mints], "a nested generate_foes leaves the outer frame"
    assert_equal [[[:ZUBAT, 9, false], [:ZUBAT, 9, false]]], r[:battles]
  end

  def test_a_roamer_is_the_games
    %w[roamer roamer_same].each do |c|
      r = run_case(c)
      assert_empty r[:mints], c
      assert_equal [[[:RAIKOU, 50, false]]], r[:battles], "#{c}: the roamer itself, not a table roll"
    end
  end

  def test_a_poke_radar_chain_is_the_games
    r = run_case("radar_same")
    assert_empty r[:mints], "the chain wrote its values over the roll: the game's"
    assert_equal [[[:PIDGEY, 3, true]]], r[:battles], "the chain's Pidgey, shiny from its patch"
    assert_equal 0, run_case("radar_rarer")[:rolls], "a rarer-slot roll is not the table's odds"
  end

  def test_an_events_battle_after_a_repelled_roll_is_the_games
    r = run_case("stale")
    assert_equal :Land, r[:type], "the repelled roll left its type"
    assert_empty r[:mints]
    assert_equal [[[:KECLEON, 30, false]]], r[:battles]
    assert_equal 0, r[:stray], "an event's battle is a battle's start"
  end

  def test_the_rolls_kept_are_bounded_and_none_when_off
    r = run_case("bounded")
    assert_equal PEMK_ROLLS_MAX, r[:rolls]
    assert_equal 0, r[:off_rolls]
  end

  def test_shadow_reports_the_tables_own_species
    r = run_case("shadow")
    assert_empty r[:mints]
    assert_equal [["Land", "SHELLOS_1", 20]], r[:reports], "the table's id (a form's), and no report for the event's battle"
  end

  def test_off_changes_nothing
    r = run_case("off")
    assert_empty r[:mints]
    assert_empty r[:reports]
    assert_equal [[[:PIDGEY, 3, false]]], r[:battles]
  end

  def test_sweet_scent_and_a_broken_chain_are_the_tables
    assert_equal [[31, "Land"], [31, "Land"]], run_case("sweet_scent")[:mints]
    r = run_case("radar_break")
    assert_equal [[31, "Land"]], r[:mints], "the roll the chain broke on was left as rolled"
  end

  def test_a_generation_outside_a_battle_is_said_once
    r = run_case("stray")
    assert_empty r[:mints]
    assert_equal [0, 0, 1], r.values_at(:off, :untyped, :stray), "said once, with a mode and an encounter under way"
  end

  def test_a_roll_changed_outside_a_handler_or_used_twice
    r = run_case("direct_write")
    assert_empty r[:mints]
    assert_equal [[[:MEW, 3, false]]], r[:battles]
    r = run_case("twice")
    assert_equal [[31, "Land"]], r[:mints], "one mint a roll"
    assert_equal [[[:ZUBAT, 9, false]], [[:PIDGEY, 3, false]]], r[:battles]
  end

  def test_a_plugins_roll_is_minted_with_its_own_type
    assert_equal [[31, "Land"]], run_case("plugin_roll")[:mints]
  end

  def test_the_grants_kept_are_bounded
    r = run_case("grants")
    refute r[:first]
    assert r[:last]
    assert_equal 16, r[:kept]
  end

  # The catch seam asks the server only for a foe it minted (the others have no mint to be
  # judged against: an older stashed one of the same species and level would be stamped).
  CATCH = <<~'RUBY'
    module PEMK
      def self.log(_m); end
      module Encounter; def self.granted?(pkmn) = pkmn.personalID == 42; end
      module Config; CATCH_VERDICT_TIMEOUT = 1; end
    end
    class Battle
      def wildBattle? = true
      def pbCaptureCalc(_pkmn, _battler, _catch_rate, _ball) = :local
    end
    load ARGV[0]
    $asked = 0
    module PEMK
      module Catch
        def self.enforcing? = true
        def self.shadow? = false
        def self.request_verdict(*) = ($asked += 1; { shakes: 4, critical: false })
      end
    end
    mon = Struct.new(:personalID)
    b = Battle.new
    print [b.pbCaptureCalc(mon.new(42), nil, nil, :POKEBALL), b.pbCaptureCalc(mon.new(7), nil, nil, :POKEBALL), $asked].inspect
  RUBY

  def test_a_catch_is_asked_for_a_minted_foe_only
    plugin = File.join(ROOT, "Plugins/PEMK/009_BattleData/005_Catch.rb")
    out = IO.popen([RbConfig.ruby, "-W0", "-e", CATCH, plugin], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:
#{out}"
    assert_equal [4, :local, 1], eval(out) # rubocop:disable Security/Eval
  end

  def test_a_seam_redefined_later_is_said_once
    r = run_case("seams")
    assert_equal ["encounter: a script loaded after PEMK redefines PokemonEncounters#choose_wild_pokemon - if it no longer " \
                  "passes the table's roll on as it is, wild encounters stay the game's (nothing minted or reported)"], r[:said]
    assert_empty r[:mints], "a copy of the roll is not the roll"
  end

  PEMK_ROLLS_MAX = 8
end
