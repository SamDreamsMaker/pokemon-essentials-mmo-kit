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
  # The sample with Brock placed at map 10 event 3, alone in his call, and the game's
  # partners listed (+partners+; nil: none listed).
  def gym_sample(partners: [])
    doc = sample
    doc["maps"]["10"] = { "name" => "Gym", "width" => 20, "height" => 20, "objects" => [],
                          "trainers" => [{ "event_id" => 3, "x" => 6, "y" => 5, "type" => "LEADER_Brock",
                                           "name" => "Brock", "version" => 0, "calls" => [0] }] }
    doc["partners"] = { "list" => partners, "computed" => false } if partners
    doc
  end

  def test_badge_sources
    doc = gym_sample
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
    assert_equal [{ map: 10, event: 3, page: 0, trainers: [["LEADER_Brock", "Brock", 0]], no_money: false, no_partner: false,
                    size: nil, call: nil }],
                 w.badge_sources(0)
    assert_equal [{ map: 12, event: 5, page: 1, trainers: nil, no_money: false, no_partner: false, size: nil, call: nil },
                  { common_event: 7 }], w.badge_sources(1)
    assert_equal [], w.badge_sources(2), "nothing the export read gives badge 2"
    assert_equal 1, w.badge_unknown.size
    assert_equal [0], w.win_bits(10, 3, "LEADER_Brock", "Brock", 0)
    assert_equal [["LEADER_Brock", "Brock", 0, 10, 3]], w.badge_battles, "the battles whose win gives a badge"
    assert_equal [], w.win_bits(10, 4, "LEADER_Brock", "Brock", 0), "another event"
    assert_equal ["a badge set the export cannot read: map 12 event 5 page 2 ($player.badges[n] = true)",
                  "badge 1 is given with no battle (map 12 event 5 page 1)",
                  "badge 1 is given with no battle (common event 7)"], w.badge_blockers
  end

  # What keeps the server from owning the badges an export gives.
  def test_badge_blockers
    doc = gym_sample
    assert_match(/predate the badge sources/, load(doc).badge_blockers[0])
    brock = ["LEADER_Brock", "Brock", 0]
    doc["badge_sources"] = {
      "list" => [{ "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [brock] }],
      "unknown" => [{ "file" => "Plugins/MyGame/x.rb", "line" => 3, "script" => "$player.badges[2] = true" }]
    }
    assert_equal ["a badge set the export cannot read: Plugins/MyGame/x.rb:3 ($player.badges[2] = true)"],
                 load(doc).badge_blockers
    doc["badge_sources"]["unknown"] = []
    assert_equal [], load(doc).badge_blockers, "a single trainer's paying win: nothing blocks"
    doc["badge_sources"]["list"] += [
      { "badge" => 1, "map" => 10, "event" => 3, "page" => 0, "trainers" => [brock], "call" => 5 },
      { "badge" => 4, "map" => 11, "event" => 4, "page" => 0, "trainers" => [["A", "A", 0], ["B", "B", 0]] },
      { "badge" => 6, "map" => 14, "event" => 7, "page" => 0, "trainers" => [["D", "D", 0]], "no_money" => true },
      { "badge" => 9, "map" => 15, "event" => 1, "page" => 0, "trainers" => [["E", "E", 0]] }
    ]
    assert_equal ["badge 4 is a battle against several trainers (map 11 event 4 page 0): no replay proves it",
                  "badge 6's battle pays nothing (map 14 event 7 page 0): no claim proves it",
                  "badge 9 is over the cap of 8",
                  "badge 9's battle gets no seed (map 15 event 1 page 0): the export does not place E E",
                  "LEADER_Brock Brock v0 (map 10 event 3) gives badges 0, 1 in different battles: " \
                  "which, the win cannot say"],
                 load(doc).badge_blockers(badges_max: 8)
    doc["badge_sources"]["list"] = [{ "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [brock], "call" => 2 },
                                    { "badge" => 1, "map" => 10, "event" => 3, "page" => 0, "trainers" => [brock], "call" => 2 }]
    assert_equal [], load(doc).badge_blockers, "one battle giving two badges gives both"
  end

  # A badge's battle the server gives no seed - or the client asks none for - is one no
  # replay proves.
  def test_badge_battles_without_a_seed
    brock = { "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] }
    sources = { "list" => [brock], "unknown" => [] }
    doc = gym_sample(partners: [["POKEMONTRAINER_May", "May", 0]]).merge("badge_sources" => sources)
    assert_equal ["badge 0's battle gets no seed (map 10 event 3 page 0): a partner may join it (POKEMONTRAINER_May May)"],
                 load(doc).badge_blockers
    sources["list"] = [brock.merge("no_partner" => true)]
    assert_equal [], load(doc).badge_blockers, "fought alone: no partner joins"
    doc = gym_sample(partners: nil).merge("badge_sources" => { "list" => [brock], "unknown" => [] })
    assert_equal ["badge 0's battle gets no seed (map 10 event 3 page 0): a partner may join it " \
                  "(the export cannot list the game's partners)"], load(doc).badge_blockers
    doc = gym_sample.merge("badge_sources" => { "list" => [brock], "unknown" => [] })
    doc["maps"]["10"]["trainers"] << { "event_id" => 3, "x" => 6, "y" => 5, "type" => "LEADER_Misty", "name" => "Misty",
                                       "version" => 0, "calls" => [0] }
    assert_equal ["badge 0's battle gets no seed (map 10 event 3 page 0): LEADER_Brock Brock shares a battle call"],
                 load(doc).badge_blockers
    doc = gym_sample.merge("badge_sources" => { "list" => [brock.merge("size" => "double", "no_partner" => true)],
                                                "unknown" => [] })
    assert_equal ["badge 0's battle gets no seed (map 10 event 3 page 0): it is a double battle"], load(doc).badge_blockers
  end

  # B2: owning the badges, the server has its clients fight a badge's battle alone - a
  # partner keeps nothing from it; what else keeps a seed away still does.
  def test_badge_battles_fought_alone
    brock = { "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] }
    [[["POKEMONTRAINER_May", "May", 0]], nil].each do |partners|
      doc = gym_sample(partners: partners).merge("badge_sources" => { "list" => [brock], "unknown" => [] })
      refute_empty load(doc).badge_blockers
      assert_equal [], load(doc).badge_blockers(alone: true), "a partner never joins (#{partners.inspect})"
    end
    doc = gym_sample.merge("badge_sources" => { "list" => [brock.merge("size" => "double")], "unknown" => [] })
    assert_equal ["badge 0's battle gets no seed (map 10 event 3 page 0): it is a double battle"],
                 load(doc).badge_blockers(alone: true)
    doc = gym_sample.merge("badge_sources" => { "list" => [brock.merge("map" => 11)], "unknown" => [] })
    assert_equal ["badge 0's battle gets no seed (map 11 event 3 page 0): the export does not place LEADER_Brock Brock"],
                 load(doc).badge_blockers(alone: true)
  end

  # The battles the clients fight alone are those a replay can prove once fought alone: a
  # sized battle, one paying nothing, an unplaced trainer, several trainers - never.
  def test_badge_battles_are_the_provable_ones
    brock = { "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] }
    listed = lambda do |*sources|
      load(gym_sample(partners: [["POKEMONTRAINER_May", "May", 0]])
             .merge("badge_sources" => { "list" => sources, "unknown" => [] })).badge_battles
    end
    assert_equal [["LEADER_Brock", "Brock", 0, 10, 3]], listed.(brock), "a partner may join: fought alone"
    assert_equal [], listed.(brock.merge("size" => "double"))
    assert_equal [], listed.(brock.merge("no_money" => true))
    assert_equal [], listed.(brock.merge("map" => 11))
    assert_equal [], listed.(brock.merge("trainers" => [["LEADER_Brock", "Brock", 0], ["CAMPER", "Liam", 0]]))
    assert_equal [], listed.(brock.merge("trainers" => nil))
    assert_equal [["LEADER_Brock", "Brock", 0, 10, 3]], listed.(brock, brock.merge("badge" => 1, "page" => 1)),
                 "one battle, listed once"
  end

  # PEMK_BADGE_IGNORE: the badge writes the operator says are not the game's keep nothing -
  # only those the export cannot read, or that give a badge with no battle.
  def test_badge_blockers_ignore
    brock = { "badge" => 0, "map" => 10, "event" => 3, "page" => 0, "trainers" => [["LEADER_Brock", "Brock", 0]] }
    doc = gym_sample.merge("badge_sources" => {
                             "list" => [brock,
                                        { "badge" => 1, "map" => 3, "event" => 7, "page" => 1 },
                                        { "badge" => 2, "common_event" => 4 },
                                        { "badge" => 3, "map" => 12, "event" => 5, "page" => 0, "trainers" => [["A", "A", 0], ["B", "B", 0]] }],
                             "unknown" => [{ "map" => 3, "event" => 7, "page" => 0, "script" => "$player.badges[i] = true" },
                                           { "common_event" => 9, "script" => "$player.badges[n] = true" },
                                           { "file" => "Plugins/MyGame/x.rb", "line" => 3, "script" => "$player.badges[2] = true" }]
                           })
    w = load(doc)
    assert_equal %w[3:7 ce:9 Plugins/MyGame/x.rb:3 ce:4], w.badge_ignorable, "Brock's battle and a several-trainers win aside"
    assert_equal 6, w.badge_blockers.length
    assert_equal ["a badge set the export cannot read: common event 9 ($player.badges[n] = true)",
                  "a badge set the export cannot read: Plugins/MyGame/x.rb:3 ($player.badges[2] = true)",
                  "badge 2 is given with no battle (common event 4)",
                  "badge 3 is a battle against several trainers (map 12 event 5 page 0): no replay proves it"],
                 w.badge_blockers(ignore: %w[3:7]), "one event: all its pages"
    assert_equal ["badge 3 is a battle against several trainers (map 12 event 5 page 0): no replay proves it"],
                 w.badge_blockers(ignore: %w[3:7 ce:9 Plugins/MyGame/x.rb:3 ce:4 12:5]), "a win's battle is no write it ignores"
    assert_equal 6, w.badge_blockers(ignore: %w[3:8 ce:7 Plugins/MyGame/x.rb:4 10:3]).length, "names that match nothing"
    assert_equal [], load(gym_sample).badge_ignorable, "an export before the badges"
  end

  # Field gates: the obstacles, the headbutt walls, the falls a player climbs, and what
  # each move needs. They feed detection: a malformed entry is left out, never an error.
  def test_field_gates
    doc = sample
    assert_nil load(doc).field_gates, "an export before the gates"
    m = doc["maps"]["7"]
    m["obstacles"] = [{ "event" => 3, "x" => 1, "y" => 0, "move" => "CUT" }, { "x" => "bad" }, { "x" => 2, "y" => 0, "move" => "FLY" }]
    m["walls"] = [{ "event" => 4, "x" => 2, "y" => 1 }]
    m["falls"] = Array.new(m["height"]) do |y|
      next "f" + ("." * (m["width"] - 1)) if y.zero?

      y == 1 ? ("." * (m["width"] - 1)) + "f" : "." * m["width"]
    end
    doc["field_gates"] = { "badges" => { "cut" => 1, "rocksmash" => 2, "strength" => 3, "waterfall" => 6 },
                           "moves" => { "cut" => true, "rocksmash" => false, "strength" => nil, "waterfall" => "yes" } }
    w = load(doc)
    assert_equal({ event: 3, move: "CUT" }, w.obstacle_at(7, 1, 0))
    assert_nil w.obstacle_at(7, 2, 0), "a move the gates do not know"
    assert w.wall_at?(7, 2, 1)
    refute w.wall_at?(7, 1, 1)
    assert w.fall?(7, 0, 0)
    refute w.fall?(7, 1, 0)
    refute w.fall?(7, 0, 99), "outside the grid"
    assert w.fall?(7, m["width"] - 1, 1)
    refute w.fall?(7, -1, 1), "a negative x is off the map, not the row's end"
    assert_equal({ badges: { cut: 1, rocksmash: 2, strength: 3, waterfall: 6 },
                   moves: { cut: true, rocksmash: false, strength: nil, waterfall: nil } }, w.field_gates)
    m["falls"] = ["ff"]   # not the map's size
    doc["field_gates"]["badges"]["cut"] = "1"
    w = load(doc)
    refute w.fall?(7, 0, 0), "malformed falls: none"
    assert_nil w.field_gates, "malformed badges: as if absent"
  end

  # Mode keys: what Surf and Dive need, and what starts a swim by itself.
  def test_field_keys
    doc = sample
    assert_nil load(doc).field_keys, "an export before the keys"
    doc["field_keys"] = { "count_badges" => true, "surf" => 4, "dive" => 7,
                          "mode_sources" => [{ "map" => 3, "event" => 9, "page" => 0, "script" => "pbStartSurfing" }, "junk"] }
    keys = load(doc).field_keys
    assert_equal({ count_badges: true, surf: 4, dive: 7,
                   sources: [{ "map" => 3, "event" => 9, "page" => 0, "script" => "pbStartSurfing" }],
                   moves: { surf: nil, dive: nil }, moves_exported: false }, keys, "an export before the move keys says nothing of them")
    assert keys.frozen? && keys[:sources].frozen? && keys[:moves].frozen?
    doc["field_keys"] = { "count_badges" => "yes", "surf" => -1, "dive" => 7, "surf_move" => true, "dive_move" => false }
    assert_equal({ count_badges: false, surf: -1, dive: 7, sources: [], moves: { surf: true, dive: false }, moves_exported: true },
                 load(doc).field_keys, "no requirement, no source; the game's Dive asks for no Pokemon")
    doc["field_keys"] = { "surf" => 4, "dive" => 7, "surf_move" => nil, "dive_move" => "yes" }
    assert_equal({ moves: { surf: nil, dive: nil }, moves_exported: true }, load(doc).field_keys.slice(:moves, :moves_exported),
                 "redefined (null) and junk are unknown")
    doc["field_keys"] = { "surf" => "4", "dive" => 7 }
    assert_nil load(doc).field_keys, "malformed: as if absent"
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
