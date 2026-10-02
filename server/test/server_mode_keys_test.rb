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

# Mode keys over the wire: a surfer or a diver needs the badge the game requires. The
# login's badge read seeds the verdicts; a badge frame or a claim reads them again at
# once, the verdicts known holding meanwhile; with no key the swim is logged and flagged,
# and under PEMK_POS_ENFORCE=on refused - the player sent back to the land it left. An
# export before the keys, a game whose scripts start swims, a debug client: no refusal.
class ServerModeKeysTest < Minitest::Test
  W = PEMK::Wire
  LAND  = [31, 2, 2].freeze
  WATER = [31, 3, 2].freeze
  CAPS  = %w[presence_v2].freeze

  def self.world(keys: { "count_badges" => true, "surf" => 4, "dive" => 7, "mode_sources" => [] })
    water = Array.new(20) { "." * 20 }
    water[2] = "..." + "w" * 4 + "." * 13
    doc = { "schema_version" => 3, "water_marks" => true,
            "maps" => { "31" => { "name" => "Lake", "width" => 20, "height" => 20, "objects" => [], "water" => water },
                        "32" => { "name" => "Sea", "width" => 20, "height" => 20, "objects" => [], "water" => water } } }
    doc["field_keys"] = keys if keys
    f = Tempfile.new(["pemk_world", ".json"])
    f.write(JSON.generate(doc))
    f.flush
    f
  end

  WORLD      = world
  NO_KEYS    = world(keys: nil)
  BY_INDEX   = world(keys: { "count_badges" => false, "surf" => 4, "dive" => 7, "mode_sources" => [] })
  WITH_BOATS = world(keys: { "count_badges" => true, "surf" => 4, "dive" => 7,
                             "mode_sources" => [{ "map" => 3, "event" => 9, "page" => 0, "script" => "pbStartSurfing" }] })

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    %i[economy_ledger economy_balances player_flags monster_transfers monsters enforcement_events money_claims]
      .each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(extra = {})
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_POS_ENFORCE" => "on", "PEMK_CLIENT_DEBUG" => "deny",
                         "PEMK_BADGE_AUTHORITY" => "off", "PEMK_MONEY_AUTHORITY" => "off",
                         "PEMK_ANOMALY_DETECTION" => "on").merge(extra)
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

  def drain(s, quiet = 0.3, first: 2.0)
    out = []
    loop do
      e = recv_env(s, out.empty? ? first : quiet)
      break if e.nil?

      out << e
    end
    out
  rescue Timeout::Error
    out
  end

  def nothing(s) = drain(s, first: 0.6)

  # A registered account holding +badges+ in the ledger, logged in (the login reads them).
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

  def pos(s, tile, mode)
    send_env(s, { type: :pos, map: tile[0], x: tile[1], y: tile[2], dir: 2, mode: mode })
  end

  def on_reactor(&block)
    done = Queue.new
    @server.instance_variable_get(:@reactor).post { done << block.call }
    Timeout.timeout(3) { done.pop }
  end

  def conn_data(id) = on_reactor { @server.instance_variable_get(:@online)[id].data }

  # The verdict on +mode+ the connection holds (a fresh one, read since a badge frame).
  def verdict(id, mode, fresh: false)
    deadline = Time.now + 3
    loop do
      v = on_reactor { @server.instance_variable_get(:@online)[id].data.dig(:mode_keys, mode) }
      return v if v && (!fresh || !v[:stale])
      flunk "no verdict within 3s" if Time.now > deadline

      sleep 0.05
    end
  end

  def flags(id, expect = nil)
    deadline = Time.now + 3
    loop do
      n = @db[:player_flags].where(account_id: id, kind: "mode_illegal").get(:count).to_i
      return n if expect.nil? || n == expect || Time.now > deadline

      sleep 0.05
    end
  end

  # The key read takes +seconds+ (it is a few ms): what the frames sent meanwhile do.
  def slow_read(seconds)
    @server.define_singleton_method(:badges_allowed) do |account_id|
      sleep seconds
      @ledger.current(account_id, :badges).to_i
    end
  end

  # Two badges where four are needed: the login's read seeds the verdict, so the first
  # frame onto the water is refused - back to the shore - and reaches no peer; a walk
  # frame flows; the next swim is refused again (a new episode: flagged again), read never.
  def test_a_swim_with_no_key_is_sent_back_to_the_shore
    start_server
    s, id = login("nokey@t.co", badges: 0b11)
    peer, = login("peer@t.co", caps: [])     # an older client: it hears every frame, repeats too
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    pos(s, WATER, :surf)
    assert_equal [[:pos_correct, 31, 2, 2]], drain(s).map { |e| e.values_at(:type, :map, :x, :y) }, "back to the shore"
    assert_empty nothing(peer), "a refused frame reaches no peer"
    assert_equal LAND, conn_data(id)[:last_pos], "the audit never moved onto the water"
    assert logs.any? { |l| l.match?(/posaudit: account #{id} surf with no key \(4 badges needed, has 2: 11\) -> sent back to the shore/) },
           logs.grep(/posaudit/).join("\n")
    assert_equal 1, flags(id, 1)
    pos(s, [31, 4, 2], :surf)                                       # still swimming: the same episode
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }
    assert_equal 1, flags(id, 2), "flagged once an episode"
    pos(s, LAND, :walk)
    assert_equal [:walk], drain(peer).map { |e| e[:mode] }, "on foot again: it flows"
    pos(s, WATER, :surf)
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }, "refused again"
    assert_equal 1, flags(id, 2), "flagged once per 30 s, like the log"
    assert_nil conn_data(id)[:mode_token], "the login's read was enough"
    assert_equal 1, logs.count { |l| l.include?("surf with no key") }, "said once"
    [s, peer].each(&:close)
  end

  # Keyless and flipping the mode at every frame: still one line and one flag per 30 s - a
  # row and a line the client could otherwise write at its frame budget.
  def test_a_surf_dive_flip_flop_is_said_and_flagged_once
    start_server
    s, id = login("flip@t.co", badges: 0b11)
    pos(s, LAND, :walk)
    drain(s)
    6.times { |i| pos(s, WATER, i.even? ? :surf : :dive) }
    assert_equal [:pos_correct] * 6, drain(s).map { |e| e[:type] }, "each refused"
    assert_equal 1, flags(id, 1)
    sleep 0.5
    assert_equal 1, flags(id), "flagged once"
    assert_equal 1, logs.count { |l| l.match?(/account #{id} (surf|dive) with no key/) }, "said once"
    s.close
  end

  # The shore left on another map (a swim begun through a warp): the way back names it,
  # and the client's remotes are asked for again there.
  def test_the_way_back_to_a_shore_on_another_map
    start_server
    s, id = login("warp@t.co", badges: 0b11)
    pos(s, LAND, :walk)
    drain(s)
    on_reactor { @server.instance_variable_get(:@online)[id].data[:sync_at] = 1.0 }
    pos(s, [32, 3, 2], :surf)
    assert_equal [[:pos_correct, 31, 2, 2]], drain(s).map { |e| e.values_at(:type, :map, :x, :y) }, "back to the shore, on its map"
    assert_nil conn_data(id)[:sync_at], "its next ask for the map's peers is honoured"
    s.close
  end

  def test_a_swim_with_the_key_flows
    start_server
    s, id = login("key@t.co", badges: 0b1111)
    peer, = login("peer2@t.co", caps: [])
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    pos(s, WATER, :surf)
    pos(s, [31, 4, 2], :surf)
    assert_equal %i[surf surf], drain(peer).map { |e| e[:mode] }
    assert_empty nothing(s)
    refute logs.any? { |l| l.match?(/account \d+ (surf|dive) with no key/) }
    assert_equal 0, flags(id)
    assert verdict(id, :surf)[:ok]
    [s, peer].each(&:close)
  end

  # By index: the fourth badge, not four of them; the Dive key surfs too (surfacing).
  def test_the_key_by_index_and_the_dive_key
    start_server({ "PEMK_WORLD" => BY_INDEX.path })
    _, id = login("four@t.co", badges: 0b1111)   # four badges, not badge 4
    refute verdict(id, :surf)[:ok]
    _, d_id = login("diver@t.co", badges: 1 << 7)   # the Dive badge alone
    assert verdict(d_id, :surf)[:ok], "the Dive key surfs"
    assert verdict(d_id, :dive)[:ok]
  end

  # Shadow and off: logged, flows. A game whose scripts start swims: logged only, no flag.
  def test_shadow_off_and_a_game_with_boats_only_log
    { "shadow" => /posenforce\[shadow\]: account \d+ surf with no key .* WOULD-CORRECT/,
      "off" => /posaudit: account \d+ surf with no key \(4 badges needed, has 0: 0\)\z/ }.each do |mode, line|
      start_server({ "PEMK_POS_ENFORCE" => mode })
      s, id = login("#{mode}@t.co")
      pos(s, LAND, :walk)
      pos(s, WATER, :surf)
      pos(s, [31, 4, 2], :surf)
      assert_empty nothing(s), "#{mode}: nothing refused"
      assert logs.any? { |l| l.match?(line) }, "#{mode}: #{logs.grep(/no key/).join("\n")}"
      assert_equal 1, flags(id, 1), "#{mode}: a sign still"
      s.close
      @server.stop
      @seen = nil
      @logs.clear
    end
    start_server({ "PEMK_WORLD" => WITH_BOATS.path })
    assert logs.any? { |l| l.match?(/WARNING mode keys: 1 script\(s\) start a swim by themselves \(map 3 event 9 page 0\) - a swim with no key is logged, never sent back/) }
    assert logs.any? { |l| l.include?("(a swim with no key is logged only: a script of the game starts swims)") }
    s, id = login("boat@t.co")
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    pos(s, [31, 4, 2], :surf)
    assert_empty nothing(s)
    assert logs.any? { |l| l.match?(/surf with no key .* \(logged only: a script of the game starts swims\)\z/) }
    assert_equal 0, flags(id), "a player may swim with no key there: no sign"
    s.close
  end

  # A badge frame reads the keys again at once: fresh before the next swim. Another
  # field's frame reads nothing.
  def test_a_badge_frame_reads_the_keys_again
    start_server
    s, id = login("later@t.co")
    peer, = login("peer3@t.co", caps: [])
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    pos(s, WATER, :surf)
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }
    pos(s, LAND, :walk)
    drain(peer)
    send_env(s, { type: :econ, field: :badges, value: 0b1111, seq: 1 })   # the badges earned (the client's word here)
    assert_equal :econ_ack, drain(s).last[:type]
    assert verdict(id, :surf, fresh: true)[:ok], "read again at once"
    assert_equal 1, conn_data(id)[:mode_token]
    pos(s, WATER, :surf)
    assert_equal [:surf], drain(peer).map { |e| e[:mode] }, "with the key now: the swim flows"
    assert_empty nothing(s)
    send_env(s, { type: :econ, field: :money, value: 100, seq: 2 })
    send_env(s, { type: :money_claim, nonce: 1, kind: "trainer", trainers: [], amount: 100 })   # money authority off: dropped
    drain(s)
    assert_equal 1, conn_data(id)[:mode_token], "another field, a claim nobody judges: nothing to read"
    [s, peer].each(&:close)
  end

  # A read that fails (the database away) leaves the verdicts as they were, stale: the
  # next swim reads again.
  def test_a_failed_read_is_tried_again_at_the_next_swim
    start_server
    s, id = login("down@t.co")
    pos(s, LAND, :walk)
    drain(s)
    @server.define_singleton_method(:badges_allowed) { |_id| raise "the database is away" }
    send_env(s, { type: :econ, field: :badges, value: 0b1111, seq: 1 })
    drain(s)
    deadline = Time.now + 3
    sleep 0.05 while conn_data(id)[:mode_job] && Time.now < deadline
    assert_equal 1, conn_data(id)[:mode_token]
    assert verdict(id, :surf)[:stale], "still the login's, stale"
    assert logs.any? { |l| l.include?("mode key read failed RuntimeError: the database is away") }
    @server.singleton_class.remove_method(:badges_allowed)
    pos(s, WATER, :surf)
    assert_equal 1, conn_data(id)[:mode_token], "not at once: a failed read waits MODE_RETRY before the next"
    on_reactor { @server.instance_variable_get(:@online)[id].data.delete(:mode_retry_at) }   # the wait over
    pos(s, [31, 4, 2], :surf)
    assert verdict(id, :surf, fresh: true)[:ok], "read again at the swim"
    assert_equal 2, conn_data(id)[:mode_token]
    s.close
  end

  # The badges move again while a read is in flight (two badge frames in one write, a
  # claim behind a save): that read predates the change - one more follows it.
  def test_a_change_during_a_read_reads_once_more
    start_server
    s, id = login("twice@t.co")
    pos(s, LAND, :walk)
    drain(s)
    slow_read(0.4)
    s.write(W.encode_split({ type: :econ, field: :badges, value: 0, seq: 1 }) +
            W.encode_split({ type: :econ, field: :badges, value: 0b1111, seq: 2 }))
    drain(s)
    deadline = Time.now + 5
    sleep 0.05 while conn_data(id)[:mode_token].to_i < 2 && Time.now < deadline
    assert_equal 2, conn_data(id)[:mode_token], "the read in flight, then one more"
    assert verdict(id, :surf, fresh: true)[:ok], "the fresh verdict is the second frame's"
    s.close
  end

  # A verdict holds until a fresh one replaces it: a walk frame on the spot, a badge
  # frame and a swim in one write buy no free frame while the keys are read again.
  def test_a_verdict_holds_until_a_fresh_one
    start_server
    s, id = login("trick@t.co")
    peer, = login("peer4@t.co", caps: [])
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    slow_read(0.5)
    s.write(W.encode_split({ type: :pos, map: 31, x: 2, y: 2, dir: 2, mode: :walk }) +
            W.encode_split({ type: :econ, field: :badges, value: 0, seq: 1 }) +
            W.encode_split({ type: :pos, map: 31, x: 3, y: 2, dir: 2, mode: :surf }))
    got = drain(s).map { |e| e[:type] }
    assert_includes got, :pos_correct, "the swim is refused from the verdict held"
    assert_equal [:walk], drain(peer).map { |e| e[:mode] }, "no free swim frame (the walk repeat reaches an older client)"
    assert_equal 1, conn_data(id)[:mode_token], "and the keys are read again"
    [s, peer].each(&:close)
  end

  # A verdict that comes after the player walked back fills the cache and says nothing:
  # the swim it judged is over. The next swim is refused from it, and said then.
  def test_a_verdict_after_the_walk_back_only_fills_the_cache
    start_server
    s, id = login("quick@t.co", badges: 0b1111)   # the key: seeded ok
    peer, = login("peer5@t.co", caps: [])
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    @db[:economy_balances].where(account_id: id, field: "badges").update(balance: 0)   # revoked meanwhile
    slow_read(0.5)
    send_env(s, { type: :econ, field: :badges, value: 0, seq: 1 })   # reads again, slowly
    drain(s)
    pos(s, WATER, :surf)                                             # the old verdict holds: it flows
    pos(s, LAND, :walk)                                              # back before the read returns
    assert_equal %i[surf walk], drain(peer).map { |e| e[:mode] }
    refute verdict(id, :surf, fresh: true)[:ok]
    assert_empty nothing(s)
    refute logs.any? { |l| l.match?(/account \d+ \w+ with no key|tick error/) }, "nothing said, nothing raised: it walks"
    assert_equal 0, flags(id)
    pos(s, WATER, :surf)
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }, "refused from the fresh verdict"
    assert logs.any? { |l| l.include?("surf with no key") }
    [s, peer].each(&:close)
  end

  # Where the land it left is not known - a session begun on the water - a swim with no
  # key is refused with no way back (the frame only dropped).
  def test_no_land_known_refuses_with_no_correction
    start_server
    s, = login("sea@t.co")
    pos(s, WATER, :walk)   # its first known tile is water
    pos(s, [31, 4, 2], :surf)
    assert_empty nothing(s), "refused, nothing sent"
    assert logs.any? { |l| l.match?(/surf with no key .* -> dropped \(no land known\)\z/) }, logs.grep(/no key/).join("\n")
    s.close
  end

  # An export before the keys, or a server that allows debug clients: nothing is checked.
  def test_an_old_export_or_a_debug_server_checks_nothing
    start_server({ "PEMK_WORLD" => NO_KEYS.path })
    assert logs.any? { |l| l.include?("mode keys: the export predates them") }
    s, id = login("old@t.co")
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    pos(s, [31, 4, 2], :surf)
    assert_empty nothing(s)
    assert_nil conn_data(id)[:mode_keys]
    s.close
    @server.stop
    @seen = nil
    @logs.clear
    start_server({ "PEMK_CLIENT_DEBUG" => "allow" })
    assert logs.any? { |l| l.include?("WARNING mode keys: client debug is allowed") }
    s, id = login("dbg@t.co")
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    pos(s, [31, 4, 2], :surf)
    assert_empty nothing(s)
    assert_nil conn_data(id)[:mode_keys]
    s.close
  end

  # Under B2 the badges the client may use are those it is shown - owned or pending.
  def test_under_enforcement_a_pending_badge_counts
    start_server
    @server.define_singleton_method(:badge_enforce?) { true }
    @server.define_singleton_method(:badge_shown) { |_id| 0b1111 }   # a win pending its replay
    _, id = login("pending@t.co", caps: %w[money_claims trainer_proof badge_hold badge_alone presence_v2])
    assert verdict(id, :surf)[:ok], "the ledger holds none; what it is shown counts"
  end

  def test_the_boot_log
    start_server
    assert logs.any? { |l| l.include?("mode keys: surf needs 4 badges, dive 7 badges (a swim with no key is sent back to the shore)") }
    assert logs.any? { |l| l.include?("mode keys: the badges are the client's word (badge authority does not enforce)") }
  end
end
