require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/position_audit"   # DB-free — no full pemk load / no Postgres

# M4 Layer B detection-only position audit: compare a presence frame's tile to the
# world model, LOG a violation, enforce nothing.
class PositionAuditTest < Minitest::Test
  # Minimal world stub so this stays a pure unit (no filesystem / no WorldData).
  class FakeWorld
    def initialize(walk: {}, warps: {}, spawns: [], conns: [], ledges: [], empty: false)
      @walk   = walk     # [map,x,y] => true/false  (absent key => nil = no grid)
      @warps  = warps    # [from,to,x,y] => true
      @spawns = spawns   # [[map,x,y], ...]
      @conns  = conns    # [[a,b], ...]
      @ledges = ledges   # [[map,x,y], ...]
      @empty  = empty
    end

    def empty?;                @empty;                      end
    def walkable?(m, x, y);    @walk.fetch([m, x, y], nil); end
    def warp_dest?(f, t, x, y); @warps[[f, t, x, y]] ? true : false; end
    def spawn_tile?(m, x, y);  @spawns.include?([m, x, y]); end
    def connected?(a, b);      @conns.any? { |c| (c[0] == a && c[1] == b) || (c[0] == b && c[1] == a) }; end
    def ledge?(m, x, y);       @ledges.include?([m, x, y]); end
  end

  def setup
    @logs   = []
    @logger = ->(m) { @logs << m }
  end

  def pa(world)
    PEMK::PositionAudit.new(world, logger: @logger)
  end

  def pa_mode(world, mode)
    PEMK::PositionAudit.new(world, logger: @logger, mode: mode)
  end

  def env(map:, x:, y:, type: :pos, mode: :walk)
    { type: type, map: map, x: x, y: y, mode: mode }
  end

  def test_first_frame_is_unchecked_and_records_position
    cd = {}
    v = pa(FakeWorld.new(walk: { [5, 1, 1] => true })).check(1, env(map: 5, x: 1, y: 1), cd)
    assert_equal :unchecked, v
    assert_equal [5, 1, 1], cd[:last_pos]
    assert_empty @logs
  end

  def test_adjacent_and_diagonal_steps_are_match
    w = FakeWorld.new(walk: { [5, 2, 2] => true })
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 2), { last_pos: [5, 1, 1] })
    assert_empty @logs
  end

  def test_noclip_on_fully_blocked_tile
    w = FakeWorld.new(walk: { [5, 2, 1] => false })
    assert_equal :noclip, pa(w).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("noclip") && m.include?("account 1") })
  end

  def test_noclip_suppressed_while_surfing
    w = FakeWorld.new(walk: { [5, 2, 1] => false })   # "blocked" water tile
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 1, mode: :surf), { last_pos: [5, 1, 1] })
    assert_empty @logs
  end

  def test_unknown_passability_is_not_noclip
    w = FakeWorld.new(walk: {})   # walkable? => nil (no grid)
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 1, 1] })
  end

  def test_map_connection_edge_step_to_out_of_bounds_is_not_noclip
    # Real observed FP: walking west off a map, local x -> -1 while crossing to a
    # stitched neighbour. walkable?(map,-1,y) is nil (out of grid), so the one-tile
    # edge step must be a silent match, never a noclip.
    w = FakeWorld.new(walk: { [2, 0, 10] => true })   # (2,-1,10) absent -> nil
    assert_equal :match, pa(w).check(1, env(map: 2, x: -1, y: 10), { last_pos: [2, 0, 10] })
    assert_empty @logs
  end

  def test_teleport_on_jump_over_one_tile
    w = FakeWorld.new(walk: { [5, 5, 5] => true })
    assert_equal :teleport, pa(w).check(1, env(map: 5, x: 5, y: 5), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("teleport") })
  end

  def test_ledge_hop_over_a_ledge_midpoint_is_not_a_teleport
    # Real observed FP: hopping a ledge is a straight 2-tile jump. 5(23,9)->5(23,11)
    # over the ledge at (23,10) must be accepted.
    w = FakeWorld.new(ledges: [[5, 23, 10]])
    assert_equal :match, pa(w).check(1, env(map: 5, x: 23, y: 11), { last_pos: [5, 23, 9] })
    assert_empty @logs
  end

  def test_two_tile_jump_without_a_ledge_midpoint_is_still_teleport
    w = FakeWorld.new(ledges: [])   # no ledge under the jump
    assert_equal :teleport, pa(w).check(1, env(map: 5, x: 23, y: 11), { last_pos: [5, 23, 9] })
  end

  def test_diagonal_two_tile_jump_is_not_a_ledge_hop
    w = FakeWorld.new(ledges: [[5, 22, 10]])   # diagonal jump is not a straight hop
    assert_equal :teleport, pa(w).check(1, env(map: 5, x: 24, y: 11), { last_pos: [5, 22, 9] })
  end

  def test_heartbeat_same_tile_is_match
    w = FakeWorld.new(walk: { [5, 1, 1] => true })
    assert_equal :match, pa(w).check(1, env(map: 5, x: 1, y: 1), { last_pos: [5, 1, 1] })
  end

  def test_stationary_on_a_blocked_tile_is_not_noclip
    # A login seeded on (or a heartbeat over) a tile the export mis-marks as blocked
    # must NOT no-clip — only a MOVE onto a blocked tile does. Guards the M4-B
    # server-spawn seed against a snap-back loop.
    w = FakeWorld.new(walk: { [5, 2, 1] => false })
    assert_equal :match, pa_mode(w, :on).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 2, 1] })
    assert_empty @logs
  end

  def test_legal_warp_destination_transfer
    w = FakeWorld.new(warps: { [5, 7, 10, 20] => true })
    assert_equal :match, pa(w).check(1, env(map: 7, x: 10, y: 20), { last_pos: [5, 3, 3] })
    assert_empty @logs
  end

  def test_spawn_tile_transfer_is_legal
    w = FakeWorld.new(spawns: [[9, 1, 1]])
    assert_equal :match, pa(w).check(1, env(map: 9, x: 1, y: 1), { last_pos: [5, 3, 3] })
  end

  def test_connected_edge_cross_is_legal
    w = FakeWorld.new(conns: [[5, 6]])
    assert_equal :match, pa(w).check(1, env(map: 6, x: 0, y: 9), { last_pos: [5, 3, 3] })
  end

  def test_illegal_cross_map_jump
    w = FakeWorld.new   # no warps/spawns/connections
    assert_equal :illegal_warp, pa(w).check(1, env(map: 99, x: 1, y: 1), { last_pos: [5, 3, 3] })
    assert(@logs.any? { |m| m.include?("illegal_warp") })
  end

  # --- M4 Layer B enforcement mode (shadow) -----------------------------------

  def test_shadow_mode_would_correct_noclip_targets_last_good_tile
    w = FakeWorld.new(walk: { [5, 2, 1] => false })
    assert_equal :noclip, pa_mode(w, :shadow).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("noclip") }, "still logs the detection line")
    assert(@logs.any? { |m| m.include?("WOULD-CORRECT") && m.include?("-> 5(1,1)") },
           "shadow logs a would-correct back to the last-good tile")
  end

  def test_shadow_mode_would_correct_illegal_warp
    assert_equal :illegal_warp, pa_mode(FakeWorld.new, :shadow).check(1, env(map: 99, x: 1, y: 1), { last_pos: [5, 3, 3] })
    assert(@logs.any? { |m| m.include?("WOULD-CORRECT") })
  end

  def test_shadow_mode_does_not_would_correct_teleport
    w = FakeWorld.new(walk: { [5, 5, 5] => true })
    assert_equal :teleport, pa_mode(w, :shadow).check(1, env(map: 5, x: 5, y: 5), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("teleport") }, "teleport is still detected")
    refute(@logs.any? { |m| m.include?("WOULD-CORRECT") }, "but teleport is not enforceable (ledge/speed FP risk)")
  end

  def test_off_mode_never_would_corrects
    w = FakeWorld.new(walk: { [5, 2, 1] => false })
    assert_equal :noclip, pa_mode(w, :off).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("noclip") })
    refute(@logs.any? { |m| m.include?("WOULD-CORRECT") })
  end

  # --- M4 Layer B enforcement mode (on: real snap-back) ------------------------

  def test_on_mode_snaps_back_illegal_warp_keeping_last_good_tile
    cd = { last_pos: [5, 3, 3] }
    v = pa_mode(FakeWorld.new, :on).check(1, env(map: 99, x: 1, y: 1), cd)
    assert_equal :illegal_warp, v
    assert_equal [5, 3, 3], cd[:last_pos],   "last_pos must NOT advance to the bad tile"
    assert_equal [5, 3, 3], cd[:correct_to], "server is signalled to snap back to the good tile"
    assert(@logs.any? { |m| m.include?("SNAP-BACK") })
  end

  def test_on_mode_snaps_back_noclip
    cd = { last_pos: [5, 1, 1] }
    v = pa_mode(FakeWorld.new(walk: { [5, 2, 1] => false }), :on).check(1, env(map: 5, x: 2, y: 1), cd)
    assert_equal :noclip, v
    assert_equal [5, 1, 1], cd[:last_pos]
    assert_equal [5, 1, 1], cd[:correct_to]
  end

  def test_on_mode_does_not_snap_back_teleport
    cd = { last_pos: [5, 1, 1] }
    v = pa_mode(FakeWorld.new(walk: { [5, 5, 5] => true }), :on).check(1, env(map: 5, x: 5, y: 5), cd)
    assert_equal :teleport, v
    assert_nil cd[:correct_to],            "teleport is not enforced (ledge/speed FP risk)"
    assert_equal [5, 5, 5], cd[:last_pos], "non-enforced verdict still advances last_pos"
  end

  def test_on_mode_repeated_violations_converge_to_same_good_tile
    cd = { last_pos: [5, 3, 3] }
    a = pa_mode(FakeWorld.new, :on)
    a.check(1, env(map: 99, x: 1, y: 1), cd)
    assert_equal [5, 3, 3], cd[:correct_to]
    cd.delete(:correct_to)   # server consumed + sent it
    a.check(1, env(map: 99, x: 2, y: 2), cd)   # client hasn't snapped back yet, sends another bad tile
    assert_equal [5, 3, 3], cd[:correct_to], "still targets the SAME good tile (no drift)"
    assert_equal [5, 3, 3], cd[:last_pos]
  end

  def test_on_mode_silent_frame_advances_and_clears_nothing
    cd = { last_pos: [5, 1, 1] }
    v = pa_mode(FakeWorld.new(walk: { [5, 2, 1] => true }), :on).check(1, env(map: 5, x: 2, y: 1), cd)
    assert_equal :match, v
    assert_equal [5, 2, 1], cd[:last_pos]
    assert_nil cd[:correct_to]
  end

  def test_same_map_warp_destination_is_not_a_teleport
    # A same-map Transfer-Player (teleport pad / spin tile) jumps far on one map;
    # it is a known warp dest, so it must NOT be flagged.
    w = FakeWorld.new(warps: { [5, 5, 20, 20] => true })
    assert_equal :match, pa(w).check(1, env(map: 5, x: 20, y: 20), { last_pos: [5, 3, 3] })
    assert_empty @logs
  end

  def test_same_map_warp_destination_on_a_blocked_tile_is_not_noclip
    # Whitelist-before-noclip: a same-map warp pad landing on a tile the passability
    # export mis-marks as blocked must be cleared by the warp whitelist, not :noclip.
    w = FakeWorld.new(walk: { [5, 20, 20] => false }, warps: { [5, 5, 20, 20] => true })
    assert_equal :match, pa_mode(w, :on).check(1, env(map: 5, x: 20, y: 20), { last_pos: [5, 3, 3] })
    assert_empty @logs
  end

  def test_empty_world_is_unchecked
    w = FakeWorld.new(empty: true)
    assert_equal :unchecked, pa(w).check(1, env(map: 5, x: 9, y: 9), { last_pos: [5, 1, 1] })
    assert_empty @logs
  end

  def test_malformed_primitives_are_bad_and_silent
    assert_equal :bad, pa(FakeWorld.new).check(1, env(map: "5", x: 1, y: 1), {})
    assert_empty @logs
  end

  def test_never_raises_on_garbage
    assert_equal :bad, pa(FakeWorld.new).check(1, {}, {})
  end
end
