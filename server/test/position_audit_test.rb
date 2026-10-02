require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/position_audit"   # DB-free — no full pemk load / no Postgres

# M4 Layer B detection-only position audit: compare a presence frame's tile to the
# world model, LOG a violation, enforce nothing.
class PositionAuditTest < Minitest::Test
  # Minimal world stub so this stays a pure unit (no filesystem / no WorldData).
  class FakeWorld
    def initialize(walk: {}, warps: {}, spawns: [], conns: [], ledges: [], srcs: [], empty: false,
                   water: nil, deep: [], rocky: [], dives: {}, surfaces: {}, dims: {})
      @walk   = walk     # [map,x,y] => true/false  (absent key => nil = no grid)
      @warps  = warps    # [from,to,x,y] => true
      @spawns = spawns   # [[map,x,y], ...]
      @conns  = conns    # [[a,b], ...]
      @ledges = ledges   # [[map,x,y], ...]
      @srcs   = srcs     # [[map,x,y], ...] warp event tiles (doors, stairs)
      @empty  = empty
      @water  = water    # nil = an export without water marks; else [[map,x,y], ...] surfable
      @deep   = deep     # [[map,x,y], ...] where Dive goes down / comes up (surfable too)
      @rocky  = rocky    # [[map,x,y], ...] deep water under a rock: a diver comes up, no surfer
      @dives  = dives    # map => the map below it
      @surfaces = surfaces # dive map => the map a diver comes up to
      @dims   = dims     # map => [width, height]
    end

    def empty?;                @empty;                      end
    def walkable?(m, x, y);    @walk.fetch([m, x, y], nil); end
    def warp_src?(m, x, y);    @srcs.include?([m, x, y]);   end
    def water_marks?;          !@water.nil?;                end
    def water?(m, x, y);       @water && (@water.include?([m, x, y]) || @deep.include?([m, x, y])); end
    def deep?(m, x, y);        @deep.include?([m, x, y]) || @rocky.include?([m, x, y]); end
    def dive_map(m);           @dives[m];                   end
    def surface_map(m);        @surfaces[m];                end
    def dims(m);               @dims[m];                    end

    def warp_dest?(f, t, x, y, reach: 0)
      @warps.keys.any? { |ff, tt, dx, dy| ff == f && tt == t && (dx - x).abs <= reach && (dy - y).abs <= reach }
    end

    def spawn_tile?(m, x, y, reach: 0)
      @spawns.any? { |sm, sx, sy| sm == m && (sx - x).abs <= reach && (sy - y).abs <= reach }
    end
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

  # --- pace: steps too fast for the game -----------------------------------------
  # An open world (no grid, no violation) and a clock the test moves: +n+ single-tile
  # steps along a row, each +dt+ after the last.
  def pace_walk(audit, cd, n, dt, from: [5, 0, 0], map: 5)
    x = from[1]
    n.times do
      @now += dt
      x += 1
      audit.check(1, env(map: map, x: x, y: from[2]), cd)
    end
    x
  end

  def pacer
    @now = 100.0
    PEMK::PositionAudit.new(FakeWorld.new, logger: @logger, clock: -> { @now })
  end

  def pace_lines = @logs.grep(/paces/)

  SAID = "posaudit: account 1 paces above 12 tiles/s: its 41 steps in hand are spent (the bike does 10)"

  # The bike, running, walking, a bike with jitter: the bucket refills faster than they
  # spend it, for as long as they go.
  def test_a_bike_a_run_and_a_walk_are_silent
    [0.1, 0.125, 0.25, 0.08].each do |dt|
      cd = { last_pos: [5, 0, 0] }
      pace_walk(pacer, cd, 400, dt)
      assert_empty pace_lines, "#{dt} s a tile"
    end
  end

  # A stall delivers a cyclist's frames in one read: the whole presence burst at one
  # instant, a live step right behind it, then the bike's pace again - the bucket takes it,
  # one step deeper than the burst.
  def test_a_delivery_stall_is_no_speedhack
    cd = { last_pos: [5, 0, 0] }
    a = pacer
    x = pace_walk(a, cd, 40, 0.0)                     # 40 steps stamped at the same time
    x = pace_walk(a, cd, 1, 0.05, from: [5, x, 0])    # the step the budget admits 50 ms later
    pace_walk(a, cd, 200, 0.1, from: [5, x, 0])       # then cycling on
    assert_empty pace_lines
  end

  # Twice the bike's speed spends the bucket in 5 s: each step earns 0.6 and spends 1, from
  # the 40 a step leaves in hand - said at the 101st, once per 30 s while it goes on; a slow
  # walk before earns no credit beyond the bucket.
  def test_a_speedhack_is_said_once_the_steps_in_hand_are_spent
    cd = { last_pos: [5, 0, 0] }
    a = pacer
    x = pace_walk(a, cd, 1000, 0.25)                  # a long walk first
    x = pace_walk(a, cd, 100, 0.05, from: [5, x, 0])
    assert_empty pace_lines, "the steps in hand"
    x = pace_walk(a, cd, 1, 0.05, from: [5, x, 0])
    assert_equal [SAID], pace_lines
    x = pace_walk(a, cd, 100, 0.05, from: [5, x, 0])  # 5 s more of it
    assert_equal 1, pace_lines.size, "said once per 30 s while it goes on"
    pace_walk(a, cd, 600, 0.05, from: [5, x, 0])      # 30 s more
    assert_equal 2, pace_lines.size, "said again after"
  end

  # Spent is spent: a long spell at twice the bike's speed leaves no debt behind, so the
  # honest bike that follows is not said when the 30 s pass.
  def test_a_spent_bucket_owes_no_debt
    cd = { last_pos: [5, 0, 0] }
    a = pacer
    x = pace_walk(a, cd, 1000, 0.05)                  # 50 s at twice the bike: said twice
    assert_equal 2, pace_lines.size
    assert_equal 0.0, cd[:pace][0], "spent, not in debt"
    pace_walk(a, cd, 400, 0.1, from: [5, x, 0])      # 40 s on the bike: nothing more to say
    assert_equal 2, pace_lines.size
  end

  # A ledge hop and a step over a map's edge are legal moves the audit lets through (a
  # match) that are no steps of the pace; a repeat or a turn in place neither: none of them
  # spends or refills - only time refills, so no legal move resets the bucket.
  def test_a_repeat_a_turn_a_hop_and_a_map_change_are_no_steps
    a = PEMK::PositionAudit.new(FakeWorld.new(ledges: [[5, 24, 0]], conns: [[5, 6]]), logger: @logger, clock: -> { @now })
    @now = 100.0
    cd = { last_pos: [5, 0, 0] }
    x = pace_walk(a, cd, 23, 0.04)                                                  # to (5, 23, 0)
    held = cd[:pace][0]
    6.times { @now += 0.04; a.check(1, env(map: 5, x: x, y: 0), cd) }             # heartbeat repeats: no step
    @now += 0.04
    a.check(1, env(map: 5, x: x, y: 0, type: :dir), cd)                            # a turn in place: no step
    assert_equal held, cd[:pace][0], "a repeat or a turn spends nothing"
    @now += 0.04
    assert_equal :match, a.check(1, env(map: 5, x: x + 2, y: 0), cd)              # a hop over the ledge at 24
    assert_equal held, cd[:pace][0], "a hop spends nothing, refills nothing"
    x += 2
    x = pace_walk(a, cd, 23, 0.04, from: [5, x, 0])                               # to (5, 48, 0)
    held = cd[:pace][0]
    @now += 0.04
    assert_equal :match, a.check(1, env(map: 6, x: x + 1, y: 0), cd)              # one tile on, over the edge to map 6
    assert_equal held, cd[:pace][0], "a map change spends nothing, refills nothing"
    assert_empty pace_lines
  end

  # A violation (a jump) leaves the bucket as it is: an empty one stays empty, and the line
  # is not said again within 30 s.
  def test_a_violation_leaves_the_bucket_as_it_is
    a = PEMK::PositionAudit.new(FakeWorld.new, logger: @logger, clock: -> { @now })
    @now = 100.0
    cd = { last_pos: [5, 0, 0] }
    x = pace_walk(a, cd, 105, 0.05)                   # said
    assert_equal 1, pace_lines.size
    @now += 0.05
    assert_equal :teleport, a.check(1, env(map: 5, x: x + 3, y: 0), cd)
    assert_equal 0.0, cd[:pace][0], "a jump refills nothing"
    pace_walk(a, cd, 110, 0.05, from: [5, x + 3, 0])  # still spent, within 30 s: not said again
    assert_equal 1, pace_lines.size
  end

  def test_noclip_on_fully_blocked_tile
    w = FakeWorld.new(walk: { [5, 2, 1] => false })
    assert_equal :noclip, pa(w).check(1, env(map: 5, x: 2, y: 1), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("noclip") && m.include?("account 1") })
  end

  # --- surfers and divers --------------------------------------------------------
  # The passability grid counts water as walls: the export's water marks say which.

  def test_a_surfer_crosses_water
    w = FakeWorld.new(walk: { [5, 2, 1] => false }, water: [[5, 2, 1]])
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 1, mode: :surf), { last_pos: [5, 1, 1] })
    assert_empty @logs
  end

  def test_a_surfer_does_not_cross_a_wall
    w = FakeWorld.new(walk: { [5, 2, 1] => false }, water: [[5, 3, 1]])
    assert_equal :noclip, pa(w).check(1, env(map: 5, x: 2, y: 1, mode: :surf), { last_pos: [5, 1, 1] })
    assert(@logs.any? { |m| m.include?("noclip") && m.include?("mode=surf") })
  end

  def test_a_surfer_through_a_wall_is_snapped_back
    w = FakeWorld.new(walk: { [5, 2, 1] => false }, water: [])
    cd = { last_pos: [5, 1, 1] }
    assert_equal :noclip, pa_mode(w, :on).check(1, env(map: 5, x: 2, y: 1, mode: :surf), cd)
    assert_equal [5, 1, 1], cd[:correct_to]
  end

  def test_a_surfer_lands_on_the_shore
    w = FakeWorld.new(walk: { [5, 2, 1] => true }, water: [])
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 1, mode: :surf), { last_pos: [5, 1, 1] })
  end

  def test_a_surfer_is_trusted_by_an_export_without_water_marks
    w = FakeWorld.new(walk: { [5, 2, 1] => false })   # water: nil - it cannot tell water from walls
    assert_equal :match, pa(w).check(1, env(map: 5, x: 2, y: 1, mode: :surf), { last_pos: [5, 1, 1] })
    assert_empty @logs
  end

  def test_a_diver_walks_the_map_below_like_the_ground
    w = FakeWorld.new(walk: { [70, 2, 1] => false })   # with or without water marks
    assert_equal :noclip, pa(w).check(1, env(map: 70, x: 2, y: 1, mode: :dive), { last_pos: [70, 1, 1] })
  end

  def sea(**more)
    FakeWorld.new(water: [[69, 3, 3]], deep: [[69, 10, 12]], dives: { 69 => 70 }, surfaces: { 70 => 69 }, **more)
  end

  def test_dive_goes_down_from_deep_water_to_the_same_tile
    assert_equal :match, pa(sea).check(1, env(map: 70, x: 10, y: 12, mode: :dive), { last_pos: [69, 10, 12] })
    assert_empty @logs
  end

  def test_surfacing_comes_up_onto_deep_water
    assert_equal :match, pa(sea).check(1, env(map: 69, x: 10, y: 12, mode: :surf), { last_pos: [70, 10, 12] })
    assert_empty @logs
  end

  # The game reports the arrival tile itself: a step off it could be a wall.
  def test_no_dive_from_shallow_water_off_the_tile_or_to_another_map
    assert_equal :illegal_warp, pa(sea).check(1, env(map: 70, x: 3, y: 3), { last_pos: [69, 3, 3] })
    assert_equal :illegal_warp, pa(sea).check(1, env(map: 70, x: 11, y: 13), { last_pos: [69, 10, 12] })
    assert_equal :illegal_warp, pa(sea).check(1, env(map: 69, x: 11, y: 13), { last_pos: [70, 10, 12] })
    assert_equal :illegal_warp, pa(sea).check(1, env(map: 71, x: 10, y: 12), { last_pos: [69, 10, 12] })
    assert_equal :illegal_warp, pa(sea).check(1, env(map: 69, x: 3, y: 3), { last_pos: [70, 3, 3] })
  end

  # The engine surfaces into the first map whose DiveMap this is, and nowhere else.
  def test_surfacing_only_into_the_engine_s_surface_map
    w = sea(dives: { 69 => 70, 72 => 70 }, deep: [[69, 10, 12], [72, 10, 12]])
    assert_equal :illegal_warp, pa(w).check(1, env(map: 72, x: 10, y: 12, mode: :surf), { last_pos: [70, 10, 12] })
  end

  # Metadata naming each map the other's DiveMap: the engine branches on diving, so
  # the way up is still the surface map's deep water.
  def test_a_dive_map_that_names_its_surface_as_its_own_dive_map
    w = sea(dives: { 69 => 70, 70 => 69 })
    assert_equal :match, pa(w).check(1, env(map: 69, x: 10, y: 12, mode: :surf), { last_pos: [70, 10, 12] })
    assert_equal :match, pa(w).check(1, env(map: 70, x: 10, y: 12, mode: :dive), { last_pos: [69, 10, 12] })
  end

  # Game_Character#moveto wraps the tile into a smaller map below.
  def test_a_smaller_map_below_wraps_the_arrival
    w = sea(deep: [[69, 30, 25]], dims: { 70 => [20, 20] })
    assert_equal :match, pa(w).check(1, env(map: 70, x: 10, y: 5, mode: :dive), { last_pos: [69, 30, 25] })
    assert_equal :illegal_warp, pa(w).check(1, env(map: 70, x: 30, y: 25, mode: :dive), { last_pos: [69, 30, 25] })
  end

  # Deep water under a rock: the engine lets a diver come up onto it, a surfer never
  # goes there (nor dives from it).
  def test_deep_water_under_a_rock
    w = sea(walk: { [69, 5, 5] => false }, rocky: [[69, 5, 5]])
    assert_equal :match, pa(w).check(1, env(map: 69, x: 5, y: 5, mode: :surf), { last_pos: [70, 5, 5] })
    assert_equal :noclip, pa(w).check(1, env(map: 69, x: 5, y: 5, mode: :surf), { last_pos: [69, 4, 5] })
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

  # --- honest moves enforcement once snapped back (autotest 040_honest_walk) ---

  def test_stepping_onto_stairs_over_a_wall_is_not_noclip
    # The house stairs: an event on a tile the export marks as a wall.
    w = FakeWorld.new(walk: { [3, 28, 2] => false }, srcs: [[3, 28, 2]])
    cd = { last_pos: [3, 29, 2] }
    assert_equal :match, pa_mode(w, :on).check(1, env(map: 3, x: 28, y: 2), cd)
    assert_nil cd[:correct_to]
    assert_empty @logs
  end

  def test_a_jump_onto_a_warp_tile_is_still_a_teleport
    w = FakeWorld.new(walk: { [3, 28, 2] => false }, srcs: [[3, 28, 2]])
    assert_equal :teleport, pa(w).check(1, env(map: 3, x: 28, y: 2), { last_pos: [3, 20, 2] })
  end

  def test_a_wall_that_holds_no_warp_is_still_noclip
    w = FakeWorld.new(walk: { [3, 27, 2] => false }, srcs: [[3, 28, 2]])
    assert_equal :noclip, pa(w).check(1, env(map: 3, x: 27, y: 2), { last_pos: [3, 26, 2] })
  end

  def test_arriving_a_step_past_the_warp_landing_is_legal
    # Into the Pokemon Lab: the door lands on (6,12), the first frame says (6,11).
    w = FakeWorld.new(warps: { [2, 4, 6, 12] => true })
    cd = { last_pos: [2, 18, 13] }
    assert_equal :match, pa_mode(w, :on).check(1, env(map: 4, x: 6, y: 11), cd)
    assert_nil cd[:correct_to]
    assert_empty @logs
  end

  def test_arriving_two_steps_past_the_landing_is_still_illegal
    w = FakeWorld.new(warps: { [2, 4, 6, 12] => true })
    assert_equal :illegal_warp, pa(w).check(1, env(map: 4, x: 6, y: 10), { last_pos: [2, 18, 13] })
  end

  def test_a_step_past_a_respawn_tile_is_legal
    w = FakeWorld.new(spawns: [[9, 1, 1]])
    assert_equal :match, pa(w).check(1, env(map: 9, x: 2, y: 1), { last_pos: [5, 3, 3] })
  end

  def test_a_step_past_a_same_map_warp_landing_is_not_a_teleport
    # Down the house stairs to (9,2), and already a step on.
    w = FakeWorld.new(warps: { [3, 3, 9, 2] => true })
    assert_equal :match, pa(w).check(1, env(map: 3, x: 9, y: 3), { last_pos: [3, 28, 2] })
    assert_empty @logs
  end

  def test_a_wall_next_to_a_warp_landing_is_still_noclip
    w = FakeWorld.new(walk: { [3, 10, 2] => false }, warps: { [3, 3, 9, 2] => true })
    assert_equal :noclip, pa(w).check(1, env(map: 3, x: 10, y: 2), { last_pos: [3, 11, 2] })
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
