require "minitest/autorun"
require "tempfile"
require "json"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/world_data"   # DB-free read-only model — no full pemk load / no Postgres

# M4 world model (schema v2): objects + passability grid + warps + spawns +
# connections + encounters, loaded from a build-time JSON export. Absent export ->
# no-op; present-but-invalid -> BOOT ERROR.
class WorldDataTest < Minitest::Test
  def setup
    @files = []
    @logs  = []
    @logger = ->(m) { @logs << m }
  end

  def teardown
    @files.each { |f| f.unlink rescue nil }
  end

  def write_world(doc)
    f = Tempfile.new(["world", ".json"])
    f.write(JSON.generate(doc))
    f.close
    @files << f
    f.path
  end

  def load(doc)
    PEMK::WorldData.new(write_world(doc), logger: @logger)
  end

  def sample
    {
      "schema_version" => 2,
      "start" => [1, 5, 5],
      "home"  => [1, 5, 6, 2],
      "connections" => [[5, 0, 3, 7, 40, 3]],
      "maps" => {
        "5" => {
          "name" => "Route 1", "width" => 4, "height" => 3,
          "objects" => [{ "kind" => "item", "item" => "POTION", "x" => 1, "y" => 1, "event_id" => 3 }],
          "passability" => ["0000", "00f0", "0000"],   # (2,1) fully blocked ('f')
          "ledges" => [[1, 2]],
          "warps" => [{ "src_x" => 2, "src_y" => 2, "dest_map" => 7, "dest_x" => 10, "dest_y" => 20, "dir" => 2, "event_id" => 9 }],
          "heal" => [5, 2, 2],
          "encounters" => { "0" => { "Land" => { "step_chance" => 21, "slots" => [[20, "PIDGEY", 2, 4]] } } }
        },
        "7" => { "name" => "Cave", "width" => 2, "height" => 2, "objects" => [], "passability" => ["00", "00"] }
      }
    }
  end

  def test_objects_index_unchanged
    w = load(sample)
    assert w.loaded?
    refute w.empty?
    assert w.map_known?(5)
    assert w.map_known?(7)
    refute w.map_known?(999)
    assert_equal "POTION", w.object_at(5, 1, 1)["item"]
    assert_nil w.object_at(5, 0, 0)
  end

  def test_walkable
    w = load(sample)
    assert_equal true,  w.walkable?(5, 0, 0)
    assert_equal false, w.walkable?(5, 2, 1)     # 'f' == fully blocked
    assert_nil w.walkable?(5, -1, 0)             # out of range -> nil (map-connection edge, not a wall)
    assert_nil w.walkable?(5, 4, 0)              # x == width -> out of range
    assert_nil w.walkable?(5, 0, 3)              # y == height -> out of range
    assert_nil w.walkable?(999, 0, 0)            # no grid -> unchecked (never flagged)
    assert_equal true, w.walkable?(7, 1, 1)
  end

  def test_ledges
    w = load(sample)
    assert w.ledge?(5, 1, 2)
    refute w.ledge?(5, 0, 0)
    refute w.ledge?(7, 1, 2)   # map 7 has no ledges
  end

  def with_water(doc = sample)
    doc["water_marks"] = true
    doc["maps"]["5"]["water"] = ["..w.", ".dwx", "...."]
    doc["maps"]["5"]["dive_map"] = 7
    doc["maps"]["7"]["surface_map"] = 5
    doc
  end

  def test_water_and_dive_maps
    w = load(with_water)
    assert w.water_marks?
    assert_equal true,  w.water?(5, 2, 0)
    assert_equal true,  w.water?(5, 1, 1)        # deep water is water too
    assert_equal false, w.water?(5, 3, 1)        # ... not under a rock: no surfer goes there
    assert_equal false, w.water?(5, 0, 0)
    assert_nil w.water?(5, 9, 0)                 # outside the grid
    assert_equal false, w.water?(7, 0, 0)        # the export marks water: no grid, no water
    assert w.deep?(5, 1, 1)
    assert w.deep?(5, 3, 1)                      # a diver may come up under the rock
    refute w.deep?(5, 2, 1)
    assert_equal 7, w.dive_map(5)
    assert_nil w.dive_map(7)
    assert_equal 5, w.surface_map(7)
    assert_nil w.surface_map(5)
    assert_equal [4, 3], w.dims(5)
    assert_nil w.dims(999)
    assert_match(/1 water grids, 1 dive maps/, w.summary)
  end

  def test_an_export_without_water_marks_says_nothing_of_water
    w = load(sample)
    refute w.water_marks?
    assert_nil w.water?(5, 2, 1)
    refute w.deep?(5, 2, 1)
  end

  def test_malformed_water_is_boot_error
    doc = with_water
    doc["maps"]["5"]["water"] = ["..w.", ".q..", "...."]
    assert_raises(RuntimeError) { load(doc) }
    doc["maps"]["5"]["water"] = ["..w.", "...."]
    assert_raises(RuntimeError) { load(doc) }
  end

  def test_warp_dest
    w = load(sample)
    assert w.warp_dest?(5, 7, 10, 20)            # the exported warp's exact dest
    refute w.warp_dest?(5, 7, 10, 21)            # wrong tile
    refute w.warp_dest?(5, 8, 10, 20)            # wrong dest map
    refute w.warp_dest?(7, 7, 10, 20)            # map 7 has no warps
    assert_equal 1, w.warps_on(5).size
    assert_empty w.warps_on(7)
  end

  def test_warp_tiles_and_a_step_of_slack
    w = load(sample)
    assert w.warp_src?(5, 2, 2)                   # the warp event's own tile
    refute w.warp_src?(5, 2, 1)
    refute w.warp_src?(7, 2, 2)                   # map 7 has no warps
    assert w.warp_dest?(5, 7, 10, 21, reach: 1)   # a step past the landing
    refute w.warp_dest?(5, 7, 10, 22, reach: 1)
    assert w.spawn_tile?(1, 5, 5)                 # the start, exactly
    assert w.spawn_tile?(1, 6, 6, reach: 1)       # a diagonal step off it
    refute w.spawn_tile?(1, 7, 5, reach: 1)
    refute w.spawn_tile?(1, 6, 6)                 # no slack unless asked
  end

  # D4: where each trainer's battle starts, so a claimed trainer battle can be
  # checked against the map the player stands on.
  def test_trainer_placement
    doc = sample
    doc["maps"]["5"]["trainers"] = [{ "event_id" => 4, "x" => 3, "y" => 8, "type" => "CAMPER",
                                      "name" => "Liam", "version" => 0 }, "junk"]
    w = load(doc)
    assert w.trainers_known?
    assert w.trainer_on_map?(5, "CAMPER", "Liam", 0)
    assert w.trainer_on_map?(5, :CAMPER, "Liam", 0)
    refute w.trainer_on_map?(7, "CAMPER", "Liam", 0)
    refute w.trainer_on_map?(5, "CAMPER", "Liam", 1)
    refute load(sample).trainers_known?   # a pre-D4 export
  end

  # Money authority: the battles the game lets be fought again, and whether the export says.
  def test_repeatable_trainers
    doc = sample
    doc["maps"]["5"]["trainers"] = [
      { "event_id" => 4, "x" => 3, "y" => 8, "type" => "CAMPER", "name" => "Liam", "version" => 0 },
      { "event_id" => 3, "x" => 6, "y" => 6, "type" => "CHAMPION", "name" => "Blue", "version" => 0, "repeatable" => true }
    ]
    assert_nil load(doc).repeatable_trainers, "an export before the mark"
    doc["trainer_marks"] = true
    w = load(doc)
    assert_equal [[5, 3, "CHAMPION", "Blue", 0]], w.repeatable_trainers
    assert_equal true, w.trainer_place(5, 3, "CHAMPION", "Blue", 0)["repeatable"]
    assert_equal false, w.trainer_place(5, 4, "CAMPER", "Liam", 0)["repeatable"]
    assert_equal 0, w.trainer_place(5, 4, "CAMPER", "Liam", 0)["page"]
    assert_equal false, w.trainer_place(5, 4, "CAMPER", "Liam", 0)["no_money"]
    refute w.battle_calls_known?, "an export from before the battle calls"
    doc["maps"]["5"]["trainers"][0]["calls"] = [0]
    w = load(doc)
    assert w.battle_calls_known?
    assert_equal [0], w.trainer_place(5, 4, "CAMPER", "Liam", 0)["calls"]
  end

  # Money authority: the partner trainers the game registers.
  def test_partner_versions
    doc = sample
    assert_nil load(doc).partner_versions("POKEMONTRAINER", "May"), "an export before the list"
    doc["partners"] = { "list" => [["POKEMONTRAINER", "May", 0], ["POKEMONTRAINER", "May", 2], "junk"], "computed" => false }
    w = load(doc)
    assert_equal [0, 2], w.partner_versions("POKEMONTRAINER", "May")
    assert_equal [], w.partner_versions("RICHBOY", "Rich")
    doc["partners"]["computed"] = true
    assert_nil load(doc).partner_versions("POKEMONTRAINER", "May"), "a partner computed at runtime: any"
  end

  # Badge authority B0: what gives each badge.
  def test_badge_sources
    doc = sample
    w = load(doc)
    assert_equal false, w.badge_marks?
    assert_nil w.badge_sources(0), "an export before the badges says nothing"
    doc["badge_sources"] = {
      "list" => [{ "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] },
                 { "badge" => 1, "map" => 12, "event" => 5, "page" => 1 },
                 { "badge" => 1, "common_event" => 7 },
                 { "badge" => -1, "map" => 1, "event" => 1 }, "junk"],
      "unknown" => [{ "map" => 12, "event" => 5, "page" => 2, "script" => "$player.badges[n] = true" }]
    }
    w = load(doc)
    assert w.badge_marks?
    assert_equal [{ map: 10, event: 3, page: 0, trainers: [["LEADER_Brock", "Brock", 0]] }], w.badge_sources(0)
    assert_equal [{ map: 12, event: 5, page: 1, trainers: nil }, { common_event: 7 }], w.badge_sources(1)
    assert_equal [], w.badge_sources(2), "nothing the export read gives badge 2"
    assert_equal 1, w.badge_unknown.size
  end

  def test_prize_events
    doc = sample
    doc["maps"]["7"]["objects"] = [{ "kind" => "prize", "item" => "MASTERBALL", "items" => %w[MASTERBALL PPUP],
                                     "x" => 1, "y" => 0, "event_id" => 17 }]
    w = load(doc)
    assert w.prize_event?(7, 17)
    refute w.prize_event?(7, 18)
    refute w.prize_event?(5, 3)   # the POTION item ball
  end

  def test_spawns_and_connections
    w = load(sample)
    assert_equal [1, 5, 5], w.start
    assert_equal [1, 5, 6, 2], w.home
    assert_equal [5, 2, 2], w.heal(5)
    assert_nil w.heal(7)
    assert_equal [[5, 0, 3, 7, 40, 3]], w.connections
    assert w.connected?(5, 7)
    assert w.connected?(7, 5)
    refute w.connected?(5, 99)
  end

  def test_edge_letter_connection_records_are_kept
    # Real compiled records are [map1, "N", off1, map2, "S", off2] — only the two map
    # ids are Integers. They must survive (connected? reads only [0]/[3]).
    doc = sample
    doc["connections"] = [[41, "N", 0, 40, "S", 0]]
    w = load(doc)
    assert_equal [[41, "N", 0, 40, "S", 0]], w.connections
    assert w.connected?(41, 40)
    assert w.connected?(40, 41)
    refute w.connected?(41, 99)
  end

  def test_encounters_passthrough
    w = load(sample)
    enc = w.encounters(5)
    assert enc.is_a?(Hash)
    assert_equal 21, enc.dig("0", "Land", "step_chance")
    assert_nil w.encounters(7)
  end

  def test_absent_file_is_no_op_not_error
    path = File.join(Dir.tmpdir, "pemk_world_missing_#{Process.pid}.json")
    w = PEMK::WorldData.new(path, logger: @logger)
    refute w.loaded?
    assert w.empty?
    assert_nil w.walkable?(5, 0, 0)
    refute w.warp_dest?(5, 7, 10, 20)
    assert(@logs.any? { |m| m.include?("absent") })
  end

  def test_v1_export_now_boot_errors
    v1 = { "schema_version" => 1, "maps" => {} }
    err = assert_raises(RuntimeError) { load(v1) }
    assert_match(/schema_version/, err.message)
  end

  # v3 is now ACCEPTED (it only adds the optional :flags manifest), so the
  # wrong-version case has to be a genuinely unknown one.
  def test_wrong_schema_version_is_boot_error
    err = assert_raises(RuntimeError) { load(sample.merge("schema_version" => 42)) }
    assert_match(/schema_version/, err.message)
  end

  def test_malformed_passability_is_boot_error
    bad = sample
    bad["maps"]["5"]["passability"] = ["000", "00f0", "0000"]   # first row wrong width
    err = assert_raises(RuntimeError) { load(bad) }
    assert_match(/passability/, err.message)
  end

  def test_non_hex_passability_is_boot_error
    bad = sample
    bad["maps"]["5"]["passability"] = ["0000", "00X0", "0000"]   # right shape, 'X' not a hex nibble
    err = assert_raises(RuntimeError) { load(bad) }
    assert_match(/passability/, err.message)
  end

  def test_malformed_json_is_boot_error
    f = Tempfile.new(["world", ".json"]); f.write("{ not json"); f.close; @files << f
    assert_raises(RuntimeError) { PEMK::WorldData.new(f.path, logger: @logger) }
  end

  def test_duplicate_tile_keeps_first_and_logs
    doc = sample
    doc["maps"]["5"]["objects"] << { "kind" => "item", "item" => "ETHER", "x" => 1, "y" => 1, "event_id" => 9 }
    w = load(doc)
    assert_equal "POTION", w.object_at(5, 1, 1)["item"]
    assert(@logs.any? { |m| m.include?("duplicate") })
  end

  def test_absent_optional_sections_tolerated
    # A map with only objects (no passability/warps/heal) still loads; missing
    # top-level start/home/connections default cleanly.
    doc = { "schema_version" => 2, "maps" => {
      "5" => { "name" => "X", "width" => 2, "height" => 2,
               "objects" => [{ "kind" => "item", "item" => "POTION", "x" => 0, "y" => 0 }] } } }
    w = load(doc)
    assert w.map_known?(5)
    assert_nil w.walkable?(5, 0, 0)   # no grid
    assert_nil w.start
    assert_nil w.home
    assert_empty w.connections
    assert_nil w.money_sources, "an export from before money authority M0"
  end

  # Money authority M0: the events that raise a balance without a request.
  def test_money_sources_pass_through
    doc = sample.merge("money_sources" => { "events" => [
      { "map" => 5, "event" => 1, "calls" => ["change_gold"], "fields" => ["money"], "amounts" => [500],
        "computed" => false }
    ] })
    src = load(doc).money_sources
    assert_equal [5, [500], false], src["events"].first.values_at("map", "amounts", "computed")
    assert src.frozen? && src["events"].first.frozen?
  end
  # --- v3: the optional flag manifest ------------------------------------------

  # An operator who has not re-exported since sovereign variables landed keeps a
  # WORKING server — v3 only ADDS a section, so v2 must stay valid.
  def test_a_v2_export_is_still_accepted_and_has_no_manifest
    w = load("schema_version" => 2, "maps" => {})
    assert_nil w.flag_manifest
    assert_equal "local", w.flag_tier(:switches, 42), "no manifest reads as all-local"
  end

  def test_a_v3_export_exposes_the_manifest_and_tiers
    w = load("schema_version" => 3, "maps" => {},
                   "flags" => { "manifest_version" => 1, "manifest_hash" => "abc",
                                "switches" => { "42" => { "tier" => "fact", "key" => "sw:gym1" },
                                                "7"  => { "tier" => "local", "why" => "unnamed" } },
                                "variables" => { "10" => { "tier" => "mirror", "key" => "var:step" } } })
    assert_equal "abc", w.flag_manifest["manifest_hash"]
    assert_equal "fact",   w.flag_tier(:switches, 42)
    assert_equal "local",  w.flag_tier(:switches, 7)
    assert_equal "mirror", w.flag_tier(:variables, 10)
    assert_equal "local",  w.flag_tier(:switches, 999), "an unclassified id degrades to local"
    assert w.flag_manifest.frozen?
  end

  def test_an_unknown_schema_version_is_still_a_boot_error
    assert_raises(RuntimeError) { load("schema_version" => 99, "maps" => {}) }
  end

end
