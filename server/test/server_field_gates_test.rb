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

# Field gates (detection): a Cut tree, a headbutt tree, a waterfall - crossed or climbed
# without the means, on the straight line a frame covers, said once a tile per epoch. An
# epoch is what the loaded maps have seen: a transfer starts one, a connection walk keeps
# it, the reports during it count; one the server never saw start is not judged.
class ServerFieldGatesTest < Minitest::Test
  W = PEMK::Wire

  # Map 31: a Cut tree at (5,2), a headbutt tree at (8,2), a waterfall at x=3, y 4..6.
  # Map 32 elsewhere (no connection): a transfer between them starts an epoch.
  def self.world(gates: true)
    rows = Array.new(10) { "." * 10 }
    falls = Array.new(10) { "." * 10 }
    (4..6).each { |y| falls[y] = "...f......" }
    doc = { "schema_version" => 3, "water_marks" => true,
            "field_keys" => { "count_badges" => false, "surf" => 4, "dive" => 7, "mode_sources" => [],
                              "surf_move" => true, "dive_move" => true },
            "maps" => {
              "31" => { "name" => "Route", "width" => 10, "height" => 10, "objects" => [], "water" => rows,
                        "obstacles" => [{ "event" => 1, "x" => 5, "y" => 2, "move" => "CUT" }],
                        "walls" => [{ "event" => 2, "x" => 8, "y" => 2 }], "falls" => falls },
              "32" => { "name" => "Town", "width" => 10, "height" => 10, "objects" => [], "water" => rows }
            } }
    if gates
      doc["field_gates"] = { "badges" => { "cut" => 1, "rocksmash" => 2, "strength" => 3, "waterfall" => 6 },
                             "moves" => { "cut" => true, "rocksmash" => true, "strength" => true, "waterfall" => true } }
    end
    f = Tempfile.new(["pemk_world", ".json"])
    f.write(JSON.generate(doc))
    f.flush
    f
  end

  WORLD    = world
  NO_GATES = world(gates: false)
  CAPS     = %w[presence_v2 swim_report field_report].freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[economy_ledger economy_balances player_flags monster_transfers monsters enforcement_events]
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

  def login(email, badges: 0, caps: CAPS)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_env(s)
    id = @db[:accounts].where(email: email).get(:id)
    @db[:economy_balances].insert(account_id: id, field: "badges", balance: badges, last_seq: 0) if badges.positive?
    send_env(s, { type: :login, email: email, password: "password1", caps: caps })
    assert_equal :login_ok, recv_env(s)[:type]
    [s, id]
  end

  def pos(s, map, x, y, mode = :walk) = send_env(s, { type: :pos, map: map, x: x, y: y, dir: 2, mode: mode })

  def team(s, moves, seq: 1)
    send_env(s, { type: :team_check, seq: seq, team: [{ "species" => "BIDOOF", "level" => 20, "moves" => moves }] })
    Timeout.timeout(2) { loop { break if recv_env(s)[:type] == :team_ack } }
  end

  # The epoch this server saw start: from map 32 to map 31 (a transfer).
  def arrive(s)
    pos(s, 32, 1, 1)
    pos(s, 31, 4, 1)
    sleep 0.2
  end

  def said(id, what) = logs.grep(/fieldaudit: account #{id} #{what}/)

  def test_a_hop_over_a_cut_tree_with_no_key
    start_server
    s, id = login("hop@t.co", badges: 0b0)
    team(s, %w[TACKLE])
    arrive(s)
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)   # over the tree at (5,2)
    sleep 0.3
    assert_equal ["fieldaudit: account #{id} crossed a cut gate (event 1) with no key (badge 1 needed; no Pokemon knowing CUT) at 31(5,2)"],
                 said(id, "crossed")
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)
    sleep 0.2
    assert_equal 1, said(id, "crossed").size, "once a tile per epoch"
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
    pos(s, 31, 6, 2)
    sleep 0.3
    assert_empty said(id, "crossed"), "cut while the map stood"
    pos(s, 32, 1, 1)              # a transfer out...
    pos(s, 31, 4, 2)              # ... and back: the tree stands again
    pos(s, 31, 6, 2)
    sleep 0.3
    assert_equal 1, said(id, "crossed a cut gate").size
    s.close
  end

  # Cut learned during the epoch counts as well (every report while the maps stood); a
  # waterfall asks for the party of the climb, not of the epoch.
  def test_a_move_learned_during_the_epoch_and_the_climbs_own_party
    start_server
    s, id = login("learn@t.co", badges: 0b1000010)
    team(s, %w[TACKLE])
    arrive(s)
    team(s, %w[CUT WATERFALL], seq: 2)   # taught, the tree cut, the fall climbed...
    team(s, %w[TACKLE], seq: 3)          # ... then both moves forgotten
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)
    sleep 0.3
    assert_empty said(id, "crossed"), "the cut happened while the map stood"
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 3, 3, :surf)
    sleep 0.3
    assert_equal 1, said(id, "climbed a waterfall with no key").size, "the climb needs Waterfall in the party now"
    s.close
  end

  # The first frames of a session (an epoch this server never saw start): not judged.
  def test_a_session_begun_past_a_tree_is_trusted
    start_server
    s, id = login("resume@t.co")
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)
    sleep 0.3
    assert_empty said(id, "crossed")
    s.close
  end

  def test_a_headbutt_tree_is_a_wall
    start_server
    s, id = login("wall@t.co")
    arrive(s)
    pos(s, 31, 7, 2)
    pos(s, 31, 9, 2)
    sleep 0.3
    assert_equal ["fieldaudit: account #{id} crossed a headbutt tree at 31(8,2)"], said(id, "crossed")
    s.close
  end

  # A climb is one frame (forced movement sends no step): up with no key is said; down,
  # or with the key, is not.
  def test_a_waterfall_climbed_with_no_key
    start_server
    s, id = login("fall@t.co", badges: 0b1000000)
    team(s, %w[SURF])
    arrive(s)
    pos(s, 31, 3, 7, :surf)
    pos(s, 31, 3, 3, :surf)   # up the fall
    sleep 0.3
    assert_equal ["fieldaudit: account #{id} climbed a waterfall with no key (no Pokemon knowing WATERFALL) at 31(3,3)"],
                 said(id, "climbed")
    pos(s, 31, 3, 7, :surf)   # down: free
    sleep 0.2
    assert_equal 1, said(id, "climbed").size
    s.close
    t, tid = login("fall2@t.co", badges: 0b1000000)
    team(t, %w[WATERFALL])
    arrive(t)
    pos(t, 31, 3, 7, :surf)
    pos(t, 31, 3, 3, :surf)
    sleep 0.3
    assert_empty said(tid, "climbed")
    t.close
  end

  # Without the cap the move is not judged (an older client reports nothing before a gate);
  # an export before the gates, or a debug server, judges nothing.
  def test_what_is_not_judged
    start_server
    s, id = login("old@t.co", badges: 0b10, caps: %w[presence_v2])
    arrive(s)
    pos(s, 31, 4, 2)
    pos(s, 31, 6, 2)
    sleep 0.3
    assert_empty said(id, "crossed"), "the badge is there; the move is not asked of an older client"
    s.close
    @server.stop
    @seen = nil
    @logs.clear
    [{ "PEMK_WORLD" => NO_GATES.path }, { "PEMK_CLIENT_DEBUG" => "allow" }].each_with_index do |env, i|
      start_server(env)
      t, tid = login("none#{i}@t.co")
      arrive(t)
      pos(t, 31, 4, 2)
      pos(t, 31, 6, 2)
      sleep 0.3
      assert_empty said(tid, "crossed"), env.inspect
      t.close
      @server.stop
      @seen = nil
      @logs.clear
    end
  end
end
