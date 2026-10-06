require "minitest/autorun"
require "socket"
require "timeout"
require "json"
require "tempfile"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Field gates (detection): a step onto a Cut tree, a rock, a boulder still standing or onto
# a headbutt tree; a waterfall climbed (one frame up on the water) - with no key, said once
# a tile per epoch and FIELD_SAID_MAX lines a minute. An epoch is what the loaded maps have
# seen: a transfer starts one, a connection walk keeps it, the reports during it count; one
# the server never saw start is not judged, nor a connection's first frame.
class ServerFieldGatesTest < Minitest::Test
  W = PEMK::Wire

  # Map 31 (20x12): a Cut tree at (5,2), a headbutt tree at (8,2), a rock at (11,2), a
  # boulder at (14,2); waterfalls at x=3 and x=16, y 4..6, and a same-map warp landing at
  # (16,3). Map 33 is connected to 31; map 32 is elsewhere (a transfer).
  def self.world(gates: true, count: false, moves: nil)
    rows = Array.new(12) { "." * 20 }
    falls = Array.new(12) { "." * 20 }
    (4..6).each { |y| falls[y] = "...f............f..." }
    doc = { "schema_version" => 3, "water_marks" => true,
            "field_keys" => { "count_badges" => count, "surf" => 4, "dive" => 7, "mode_sources" => [],
                              "surf_move" => true, "dive_move" => true },
            "connections" => [[31, "N", 0, 33, "S", 0]],
            "maps" => {
              "31" => { "name" => "Route", "width" => 20, "height" => 12, "objects" => [], "water" => rows,
                        "obstacles" => [{ "event" => 1, "x" => 5, "y" => 2, "move" => "CUT" },
                                        { "event" => 3, "x" => 11, "y" => 2, "move" => "ROCKSMASH" },
                                        { "event" => 4, "x" => 14, "y" => 2, "move" => "STRENGTH" }],
                        "walls" => [{ "event" => 2, "x" => 8, "y" => 2 }], "falls" => falls,
                        "warps" => [{ "src_x" => 18, "src_y" => 10, "dest_map" => 31, "dest_x" => 16, "dest_y" => 3 }] },
              "32" => { "name" => "Town", "width" => 10, "height" => 10, "objects" => [], "water" => Array.new(10) { "." * 10 } },
              "33" => { "name" => "North", "width" => 20, "height" => 12, "objects" => [], "water" => rows }
            } }
    if gates
      doc["field_gates"] = { "badges" => { "cut" => 1, "rocksmash" => 2, "strength" => 3, "waterfall" => 6 },
                             "moves" => moves || { "cut" => true, "rocksmash" => true, "strength" => true, "waterfall" => true } }
    end
    f = Tempfile.new(["pemk_world", ".json"])
    f.write(JSON.generate(doc))
    f.flush
    f
  end

  WORLD    = world
  NO_GATES = world(gates: false)
  COUNTED  = world(count: true)
  UNKNOWN  = world(moves: { "cut" => nil, "rocksmash" => false, "strength" => true, "waterfall" => true })
  CAPS     = %w[presence_v2 swim_report field_report].freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[economy_ledger economy_balances player_flags monster_transfers monsters enforcement_events characters]
      .each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {})
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_CLIENT_DEBUG" => "deny").merge(extra)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    @seen ||= []
    @seen << @logs.pop until @logs.empty?
    @seen
  end

  def send_env(s, e) = s.write(W.encode_split(e))

  def recv_env(s, timeout = 2)
    Timeout.timeout(timeout) do
      h = s.read(4)
      return nil if h.nil?

      W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
    end
  end

  def register(email, badges: 0, at: nil)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_env(s)
    s.close
    id = @db[:accounts].where(email: email).get(:id)
    @db[:economy_balances].insert(account_id: id, field: "badges", balance: badges, last_seq: 0) if badges.positive?
    @db[:characters].insert(account_id: id, last_map: at[0], last_x: at[1], last_y: at[2], updated_at: Time.now) if at
    id
  end

  def connect(email, caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    ok = recv_env(s)
    assert_equal :login_ok, ok[:type]
    @token = ok[:token]
    s
  end

  # A reconnect that resumes its session: the client kept its maps.
  def resume(token, caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :auth, token: token, resume: true, caps: caps })
    assert_equal :auth_ok, recv_env(s)[:type]
    s
  end

  def login(email, badges: 0, caps: CAPS, at: nil)
    id = register(email, badges: badges, at: at)
    [connect(email, caps: caps), id]
  end

  def pos(s, map, x, y, mode = :walk) = send_env(s, { type: :pos, map: map, x: x, y: y, dir: 2, mode: mode })

  def team(s, moves, seq: 1)
    send_env(s, { type: :team_check, seq: seq, team: [{ "species" => "BIDOOF", "level" => 20, "moves" => moves }] })
    Timeout.timeout(2) { loop { break if recv_env(s)[:type] == :team_ack } }
  end

  # Waits until the server has read everything sent before (the frames of one socket are
  # handled in order).
  def settle(s)
    send_env(s, { type: :ping, t: 7 })
    Timeout.timeout(3) { loop { break if recv_env(s)[:type] == :pong } }
  end

  # The epoch this server saw start: from map 32 to map 31 (a transfer).
  def arrive(s, x = 4, y = 1)
    pos(s, 32, 1, 1)
    pos(s, 31, x, y)
  end

  def said(id, what) = logs.grep(/fieldaudit: account #{id} #{what}/)

  def on_reactor
    done = Queue.new
    @server.instance_variable_get(:@reactor).post { done << yield }
    Timeout.timeout(3) { done.pop }
  end

  def test_a_step_onto_a_cut_tree_with_no_key
    start_server
    s, id = login("hop@t.co")
    team(s, %w[TACKLE])
    arrive(s)
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)   # a hop over it: a frame longer than a step is a gap, not judged here
    pos(s, 31, 5, 0)
    pos(s, 31, 5, 2)   # nor one that lands on it (a cutscene walks with no frame)
    settle(s)
    assert_empty said(id, "crossed")
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)   # a step onto the tree
    settle(s)
    assert_equal ["fieldaudit: account #{id} crossed a cut gate (event 1) with no key (badge 1 needed; no Pokemon knowing CUT) at 31(5,2)"],
                 said(id, "crossed")
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    settle(s)
    assert_equal 1, said(id, "crossed").size, "once a tile per epoch"
    s.close
  end

  # A rock and a boulder are judged by their own move and badge.
  def test_a_rock_and_a_boulder
    start_server
    s, id = login("rock@t.co", badges: 0b100)   # badge 2 (Rock Smash), not 3 (Strength)
    team(s, %w[ROCKSMASH])
    arrive(s, 10, 1)
    pos(s, 31, 10, 2)
    pos(s, 31, 11, 2)   # the rock: the key is there
    pos(s, 31, 13, 1)
    pos(s, 31, 13, 2)
    pos(s, 31, 14, 2)   # the boulder: no Strength, no badge 3
    settle(s)
    assert_equal ["fieldaudit: account #{id} crossed a strength gate (event 4) with no key (badge 3 needed; no Pokemon knowing STRENGTH) at 31(14,2)"],
                 said(id, "crossed")
    s.close
  end

  # The key held while the maps stood: a tree cut with Cut, then the Cut Pokemon gone, is
  # still down; a transfer out and back stands it again.
  def test_the_epoch_remembers_the_cut
    start_server
    s, id = login("cut@t.co", badges: 0b10)
    team(s, %w[CUT])
    arrive(s)
    team(s, %w[TACKLE], seq: 2)   # traded away after the cut
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    settle(s)
    assert_empty said(id, "crossed"), "cut while the map stood"
    pos(s, 32, 1, 1)              # a transfer out...
    pos(s, 31, 4, 2)              # ... and back: the tree stands again
    pos(s, 31, 5, 2)
    settle(s)
    assert_equal 1, said(id, "crossed a cut gate").size
    s.close
  end

  # A connection walk keeps what the maps saw: the Cut learned before it still counts.
  def test_a_connection_walk_keeps_the_epoch
    start_server
    s, id = login("walk@t.co", badges: 0b10)
    team(s, %w[CUT])
    arrive(s)
    team(s, %w[TACKLE], seq: 2)
    pos(s, 31, 4, 0)
    pos(s, 33, 4, 11)             # over the edge, to the connected map...
    pos(s, 31, 4, 0)              # ... and back
    pos(s, 31, 4, 1)
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    settle(s)
    assert_empty said(id, "crossed"), "a connection walk keeps the epoch"
    s.close
  end

  # Cut learned during the epoch counts as well (every report while the maps stood), and
  # only the gates' moves are kept; a waterfall asks for the party of the climb, not of
  # the epoch.
  def test_a_move_learned_during_the_epoch_and_the_climbs_own_party
    start_server
    s, id = login("learn@t.co", badges: 0b1000010)
    team(s, %w[TACKLE])
    arrive(s)
    team(s, %w[CUT WATERFALL] + (1..62).map { |i| "JUNK#{i}" }, seq: 2)   # taught, the tree cut, the fall climbed...
    team(s, %w[TACKLE], seq: 3)                                             # ... then both moves forgotten
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    settle(s)
    assert_empty said(id, "crossed"), "the cut happened while the map stood"
    assert_equal Set["CUT"], on_reactor { @server.instance_variable_get(:@field_epochs)[id][:moves].dup }, "the gates' moves alone"
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 3, 3, :surf)
    settle(s)
    assert_equal 1, said(id, "climbed a waterfall with no key").size, "the climb needs Waterfall in the party now"
    s.close
  end

  # The first frames of a session (an epoch this server never saw start): not judged.
  def test_a_session_begun_past_a_tree_is_trusted
    start_server
    s, id = login("resume@t.co")
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    settle(s)
    assert_empty said(id, "crossed")
    s.close
  end

  # A connection's first frame starts from the tile its login read - the last saved, here
  # on another map (a server restarted since): it starts no judged epoch.
  def test_the_logins_tile_is_no_step
    start_server
    s, id = login("seed@t.co", at: [32, 1, 1])
    pos(s, 31, 4, 2)      # where the client is: a tree it cut before the restart is down
    pos(s, 31, 5, 2)
    settle(s)
    assert_empty said(id, "crossed")
    s.close
  end

  # A resume goes on with the epoch where it stood (judged: the badge at once, the move once
  # this connection reported its party); a login (a save loaded) or a resume elsewhere
  # starts an unknown one (not judged).
  def test_a_resume_keeps_the_epoch_only_on_its_maps
    start_server
    s, id = login("again@t.co")
    token = @token
    team(s, %w[TACKLE])
    arrive(s)
    settle(s)
    s.close
    t = resume(token)
    pos(t, 31, 4, 2)
    pos(t, 31, 5, 2)
    settle(t)
    assert_equal ["fieldaudit: account #{id} crossed a cut gate (event 1) with no key (badge 1 needed) at 31(5,2)"],
                 said(id, "crossed"), "the same maps: the epoch goes on; no party reported here yet"
    team(t, %w[TACKLE])
    pos(t, 31, 10, 1)
    pos(t, 31, 10, 2)
    pos(t, 31, 11, 2)
    settle(t)
    assert_equal "fieldaudit: account #{id} crossed a rocksmash gate (event 3) with no key (badge 2 needed; no Pokemon knowing ROCKSMASH) at 31(11,2)",
                 said(id, "crossed").last
    t.close
    u = connect("again@t.co")   # a login: the save it loads may be older than the epoch
    pos(u, 31, 7, 2)
    pos(u, 31, 8, 2)
    settle(u)
    v = resume(@token)
    u.close
    pos(v, 33, 7, 3)            # a resume first seen elsewhere: unknown too
    pos(v, 31, 7, 11)           # a connection walk: still unknown
    pos(v, 31, 7, 2)
    pos(v, 31, 8, 2)
    settle(v)
    assert_empty said(id, "crossed a headbutt"), "epochs this server never saw start"
    v.close
  end

  def test_a_headbutt_tree_is_a_wall
    start_server
    s, id = login("wall@t.co")
    arrive(s)
    pos(s, 31, 7, 2)
    pos(s, 31, 8, 2)
    pos(s, 31, 7, 1)
    pos(s, 31, 8, 2)      # diagonal: frames lost, not judged
    settle(s)
    assert_equal ["fieldaudit: account #{id} crossed a headbutt tree at 31(8,2)"], said(id, "crossed")
    s.close
  end

  # A climb is one frame on the water (forced movement sends no step): up with no key is
  # said; down, with the key, on foot (a bridge), or as a warp lands, is not.
  def test_a_waterfall_climbed_with_no_key
    start_server
    s, id = login("fall@t.co", badges: 0b1000000)
    team(s, %w[SURF])
    arrive(s)
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 3, 3, :surf)   # up the fall
    settle(s)
    assert_equal ["fieldaudit: account #{id} climbed a waterfall with no key (no Pokemon knowing WATERFALL) at 31(3,3)"],
                 said(id, "climbed")
    pos(s, 31, 3, 7, :surf)   # down: free
    pos(s, 31, 3, 9, :surf)   # down from right under it: free too
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 4, 3, :surf)   # askew from under it: frames lost
    pos(s, 31, 16, 7, :surf)
    pos(s, 31, 16, 3, :surf)  # a same-map warp lands here
    pos(s, 31, 3, 7)
    pos(s, 31, 3, 2)          # on foot from right under it: over a bridge
    pos(s, 31, 3, 9, :surf)
    pos(s, 31, 3, 1, :surf)   # up from further below: a gap, not where a climb starts
    settle(s)
    assert_equal 1, said(id, "climbed").size
    s.close
    t, tid = login("fall2@t.co", badges: 0b1000000)
    team(t, %w[WATERFALL])
    arrive(t)
    pos(t, 31, 3, 7, :surf)
    pos(t, 31, 3, 3, :surf)
    settle(t)
    assert_empty said(tid, "climbed")
    t.close
  end

  # Off the map there is no line to walk: neither judged nor built.
  def test_a_frame_off_the_map
    start_server
    s, id = login("off@t.co")
    team(s, %w[SURF])
    arrive(s)
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 3, -4, :surf)    # up past the fall, off the map
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, -1, 7, :surf)
    pos(s, 31, -1, 3, :surf)
    pos(s, 31, 3, 99, :surf)    # from off the map up past the fall
    pos(s, 31, 3, 3, :surf)
    settle(s)
    assert_empty said(id, "climbed")
    s.close
  end

  # Without the cap the move is not judged (an older client reports nothing before a gate)
  # but the badge is; an export before the gates, or a debug server, judges nothing.
  def test_what_is_not_judged
    start_server
    s, id = login("old@t.co", badges: 0b10, caps: %w[presence_v2])
    team(s, %w[TACKLE])   # an older client reports its party too, just not before a gate
    arrive(s)
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)
    pos(s, 31, 10, 1)
    pos(s, 31, 10, 2)
    pos(s, 31, 11, 2)
    settle(s)
    assert_equal ["fieldaudit: account #{id} crossed a rocksmash gate (event 3) with no key (badge 2 needed) at 31(11,2)"],
                 said(id, "crossed"), "the badge is judged; the move is not asked of an older client"
    s.close
    @server.stop
    @seen = nil
    @logs.clear
    [{ "PEMK_WORLD" => NO_GATES.path }, { "PEMK_CLIENT_DEBUG" => "allow" }].each_with_index do |env, i|
      start_server(env)
      t, tid = login("none#{i}@t.co")
      team(t, %w[TACKLE])
      arrive(t)
      pos(t, 31, 4, 2)
      pos(t, 31, 5, 2)
      settle(t)
      assert_empty said(tid, "crossed"), env.inspect
      t.close
      @server.stop
      @seen = nil
      @logs.clear
    end
  end

  # A game that counts badges asks for that many; a move whose function a script redefines
  # skips its gate; one that asks for no Pokemon leaves the badge.
  def test_counted_badges_and_unknown_rules
    start_server("PEMK_WORLD" => COUNTED.path)
    s, id = login("count@t.co", badges: 0b1001)   # two badges, neither the first nor the second
    team(s, %w[CUT ROCKSMASH STRENGTH])
    arrive(s)
    pos(s, 31, 4, 2)
    pos(s, 31, 5, 2)                               # one badge needed: two held
    pos(s, 31, 10, 1)
    pos(s, 31, 10, 2)
    pos(s, 31, 11, 2)                              # two needed
    pos(s, 31, 13, 1)
    pos(s, 31, 13, 2)
    pos(s, 31, 14, 2)                              # three needed
    settle(s)
    assert_equal ["fieldaudit: account #{id} crossed a strength gate (event 4) with no key (3 badges needed) at 31(14,2)"],
                 said(id, "crossed")
    s.close
    z, zid = login("nobadge@t.co")
    team(z, %w[TACKLE])
    arrive(z)
    pos(z, 31, 4, 2)
    pos(z, 31, 5, 2)
    settle(z)
    assert_equal ["fieldaudit: account #{zid} crossed a cut gate (event 1) with no key (1 badge needed; no Pokemon knowing CUT) at 31(5,2)"],
                 said(zid, "crossed")
    z.close
    @server.stop
    @seen = nil
    @logs.clear
    start_server("PEMK_WORLD" => UNKNOWN.path)
    t, tid = login("rules@t.co", badges: 0b100)
    team(t, %w[TACKLE])
    arrive(t)
    pos(t, 31, 4, 2)
    pos(t, 31, 5, 2)    # pbCut redefined: skipped
    pos(t, 31, 10, 1)
    pos(t, 31, 10, 2)
    pos(t, 31, 11, 2)   # pbRockSmash asks for no Pokemon, the badge is there
    settle(t)
    assert_empty said(tid, "crossed")
    t.close
  end

  # Once a tile per epoch - and a door walked to and fro starts epochs: FIELD_SAID_MAX lines
  # a minute an account, the next one counting those held back.
  def test_the_lines_are_held_to_a_rate
    start_server
    s, id = login("flood@t.co")
    12.times do
      pos(s, 32, 1, 1)
      pos(s, 31, 7, 2)
      pos(s, 31, 8, 2)
    end
    settle(s)
    assert_equal 10, said(id, "crossed a headbutt").size
    on_reactor { @server.instance_variable_get(:@field_epochs)[id][:rate][:at] -= 61 }
    pos(s, 31, 7, 2)
    pos(s, 31, 8, 2)   # the tile held back, in the same epoch: told now
    settle(s)
    assert_equal "fieldaudit: account #{id} crossed a headbutt tree at 31(8,2) (2 more held back before it)", said(id, "crossed").last
    s.close
  end

  # An epoch not walked for FIELD_EPOCH_TTL is forgotten.
  def test_an_idle_epoch_is_forgotten
    start_server
    s, id = login("idle@t.co")
    arrive(s)
    settle(s)
    gone = on_reactor do
      @server.instance_variable_get(:@field_epochs)[id][:at] -= PEMK::Server::FIELD_EPOCH_TTL + 1
      @server.instance_variable_set(:@last_limiter_prune, nil)
      @server.send(:maybe_prune_limiter)
      @server.instance_variable_get(:@field_epochs).key?(id)
    end
    refute gone
    s.close
  end
end
