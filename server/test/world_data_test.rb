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

  def test_warp_dest
    w = load(sample)
    assert w.warp_dest?(5, 7, 10, 20)            # the exported warp's exact dest
    refute w.warp_dest?(5, 7, 10, 21)            # wrong tile
    refute w.warp_dest?(5, 8, 10, 20)            # wrong dest map
    refute w.warp_dest?(7, 7, 10, 20)            # map 7 has no warps
    assert_equal 1, w.warps_on(5).size
    assert_empty w.warps_on(7)
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

  def test_wrong_schema_version_is_boot_error
    err = assert_raises(RuntimeError) { load(sample.merge("schema_version" => 3)) }
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
  end
end
