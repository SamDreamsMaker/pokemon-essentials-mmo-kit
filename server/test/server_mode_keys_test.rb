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
# keys are read once per transition, off the reactor; with no key the swim is logged and
# flagged, and under PEMK_POS_ENFORCE=on refused - the player sent back to the land it
# left. A badge frame or a claim clears the verdict; an export before the keys, a game
# whose scripts start swims, a debug client: no refusal.
class ServerModeKeysTest < Minitest::Test
  W = PEMK::Wire
  LAND  = [31, 2, 2].freeze
  WATER = [31, 3, 2].freeze

  def self.world(keys: { "count_badges" => true, "surf" => 4, "dive" => 7, "mode_sources" => [] })
    water = Array.new(20) { "." * 20 }
    water[2] = "..." + "w" * 4 + "." * 13
    doc = { "schema_version" => 3, "water_marks" => true,
            "maps" => { "31" => { "name" => "Lake", "width" => 20, "height" => 20, "objects" => [], "water" => water } } }
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

  def login(email, badges: 0)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_env(s)
    send_env(s, { type: :login, email: email, password: "password1", caps: %w[presence_v2] })
    lo = recv_env(s)
    @db[:economy_balances].insert(account_id: lo[:account_id], field: "badges", balance: badges, last_seq: 0) if badges.positive?
    [s, lo[:account_id]]
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

  # The key read runs off the reactor: wait for its verdict.
  def verdict(id, mode)
    deadline = Time.now + 3
    loop do
      v = on_reactor { @server.instance_variable_get(:@online)[id].data.dig(:mode_keys, mode) }
      return v if v
      flunk "no verdict within 3s" if Time.now > deadline

      sleep 0.05
    end
  end

  def flags(id) = @db[:player_flags].where(account_id: id, kind: "mode_illegal").count

  # The key read takes +seconds+ (it is a few ms): what the frames sent meanwhile do.
  def slow_read(seconds)
    @server.define_singleton_method(:badges_allowed) do |account_id|
      sleep seconds
      @ledger.current(account_id, :badges).to_i
    end
  end

  # Onto the water from the land with two badges where four are needed: the first frame
  # flows (the read is on its way), the next ones are refused back to the shore; a
  # walk frame ends it; surfing again is refused from the cache, read once.
  def test_a_swim_with_no_key_is_sent_back_to_the_shore
    start_server
    s, id = login("nokey@t.co", badges: 0b11)
    peer, = login("peer@t.co")
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    slow_read(0.5)
    pos(s, WATER, :surf)
    pos(s, [31, 4, 2], :surf)                                       # a second one, before the verdict
    assert_equal %i[surf surf], drain(peer).map { |e| e[:mode] }, "the first frames flow (the read is on its way)"
    refute verdict(id, :surf)[:ok]
    assert_equal 1, conn_data(id)[:mode_token], "one read for the two frames"
    pos(s, [31, 5, 2], :surf)
    assert_equal [[:pos_correct, 31, 2, 2]], drain(s).map { |e| e.values_at(:type, :map, :x, :y) }, "back to the shore"
    assert_empty nothing(peer), "a refused frame reaches no peer"
    assert_equal [31, 4, 2], conn_data(id)[:last_pos], "the frames before the verdict moved it; a refused one never does"
    assert logs.any? { |l| l.match?(/posaudit: account #{id} surf with no key \(4 badges needed, has 2: 11\) -> sent back to the shore/) },
           logs.grep(/posaudit/).join("\n")
    deadline = Time.now + 3
    sleep 0.05 while flags(id).zero? && Time.now < deadline
    assert_equal 1, flags(id)
    pos(s, LAND, :walk)
    assert_equal [:walk], drain(peer).map { |e| e[:mode] }, "on foot again: it flows"
    pos(s, WATER, :surf)
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }, "refused at once from the cache"
    assert_equal 1, conn_data(id)[:mode_token], "read once"
    assert_equal 1, logs.count { |l| l.include?("surf with no key") }, "said once"
    [s, peer].each(&:close)
  end

  def test_a_swim_with_the_key_flows
    start_server
    s, id = login("key@t.co", badges: 0b1111)
    peer, = login("peer2@t.co")
    pos(peer, [31, 5, 5], :walk)
    pos(s, LAND, :walk)
    [s, peer].each { |x| drain(x) }
    pos(s, WATER, :surf)
    assert verdict(id, :surf)[:ok]
    pos(s, [31, 4, 2], :surf)
    assert_equal %i[surf surf], drain(peer).map { |e| e[:mode] }
    assert_empty nothing(s)
    refute logs.any? { |l| l.match?(/account \d+ (surf|dive) with no key/) }
    assert_equal 0, flags(id)
    [s, peer].each(&:close)
  end

  # By index: the fourth badge, not four of them; the Dive key surfs too (surfacing).
  def test_the_key_by_index_and_the_dive_key
    start_server({ "PEMK_WORLD" => BY_INDEX.path })
    s, id = login("four@t.co", badges: 0b1111)   # four badges, not badge 4
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    refute verdict(id, :surf)[:ok]
    d, d_id = login("diver@t.co", badges: 1 << 7)   # the Dive badge alone
    pos(d, LAND, :walk)
    pos(d, WATER, :surf)
    assert verdict(d_id, :surf)[:ok], "the Dive key surfs"
    pos(d, WATER, :dive)
    assert verdict(d_id, :dive)[:ok]
    [s, d].each(&:close)
  end

  # Shadow and off: logged, flows. A game whose scripts start swims: never sent back.
  def test_shadow_off_and_a_game_with_boats_only_log
    { "shadow" => /posenforce\[shadow\]: account \d+ surf with no key .* WOULD-CORRECT/,
      "off" => /posaudit: account \d+ surf with no key \(4 badges needed, has 0: 0\)\z/ }.each do |mode, line|
      start_server({ "PEMK_POS_ENFORCE" => mode })
      s, id = login("#{mode}@t.co")
      pos(s, LAND, :walk)
      pos(s, WATER, :surf)
      refute verdict(id, :surf)[:ok]
      pos(s, [31, 4, 2], :surf)
      assert_empty nothing(s), "#{mode}: nothing refused"
      assert logs.any? { |l| l.match?(line) }, "#{mode}: #{logs.grep(/no key/).join("\n")}"
      s.close
      @server.stop
      @seen = nil
      @logs.clear
    end
    start_server({ "PEMK_WORLD" => WITH_BOATS.path })
    assert logs.any? { |l| l.match?(/WARNING mode keys: 1 script\(s\) start a swim by themselves \(map 3 event 9 page 0\) - a swim with no key is logged, never sent back/) }
    s, id = login("boat@t.co")
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    refute verdict(id, :surf)[:ok]
    pos(s, [31, 4, 2], :surf)
    assert_empty nothing(s)
    assert logs.any? { |l| l.match?(/surf with no key .* -> refused\z/) }
    s.close
  end

  # A badge frame clears the verdict: the keys are read again at the next swim.
  def test_a_badge_frame_clears_the_verdict
    start_server
    s, id = login("later@t.co")
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    refute verdict(id, :surf)[:ok]
    pos(s, LAND, :walk)
    send_env(s, { type: :econ, field: :badges, value: 0b1111, seq: 1 })   # the badges earned (the client's word here)
    assert_equal :econ_ack, drain(s).last[:type]
    peer, = login("peer3@t.co")
    pos(peer, [31, 5, 5], :walk)
    [s, peer].each { |x| drain(x) }
    pos(s, WATER, :surf)
    assert verdict(id, :surf)[:ok], "read again"
    assert_equal 2, conn_data(id)[:mode_token]
    pos(s, [31, 4, 2], :surf)
    assert_equal %i[surf surf], drain(peer).map { |e| e[:mode] }, "with the key now: the swim flows"
    assert_empty nothing(s), "no correction: the walk ended the denied episode"
    [s, peer].each(&:close)
  end

  # Where the land it left is not known - a session begun on the water - a swim with no
  # key is refused with no way back (the frame only dropped).
  def test_no_land_known_refuses_with_no_correction
    start_server
    s, id = login("sea@t.co")
    pos(s, WATER, :walk)   # its first known tile is water
    pos(s, [31, 4, 2], :surf)
    refute verdict(id, :surf)[:ok]
    pos(s, [31, 5, 2], :surf)
    assert_empty nothing(s), "refused, nothing sent"
    assert logs.any? { |l| l.match?(/surf with no key .* -> refused\z/) }, logs.grep(/no key/).join("\n")
    s.close
  end

  # A verdict that comes after the player walked back fills the cache and says nothing:
  # the swim it judged is over. The next swim is refused from it, and said then.
  def test_a_verdict_after_the_walk_back_only_fills_the_cache
    start_server
    s, id = login("quick@t.co")
    slow_read(0.5)
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    pos(s, LAND, :walk)                                             # back before the read returns
    cached = verdict(id, :surf)
    refute cached[:ok]
    assert_empty nothing(s)
    refute logs.any? { |l| l.match?(/account \d+ surf with no key/) }, "nothing said: it walks"
    assert_equal 0, flags(id)
    pos(s, WATER, :surf)
    assert_equal [:pos_correct], drain(s).map { |e| e[:type] }, "refused from the cache"
    assert logs.any? { |l| l.include?("surf with no key") }
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
    assert_nil conn_data(id)[:mode_token]
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
    assert_nil conn_data(id)[:mode_token]
    s.close
  end

  # Under B2 the badges the client may use are those it is shown - owned or pending.
  def test_under_enforcement_a_pending_badge_counts
    start_server
    s, id = login("pending@t.co")   # the ledger holds none
    @server.define_singleton_method(:badge_enforce?) { true }       # after the login (it would ask for B2's caps)
    @server.define_singleton_method(:badge_shown) { |_id| 0b1111 }  # what the client is shown: a win pending its replay
    pos(s, LAND, :walk)
    pos(s, WATER, :surf)
    assert verdict(id, :surf)[:ok]
    s.close
  end

  def test_the_boot_log
    start_server
    assert logs.any? { |l| l.include?("mode keys: surf needs 4 badges, dive 7 badges (a swim with no key is sent back to the shore)") }
    assert logs.any? { |l| l.include?("mode keys: the badges are the client's word (badge authority does not enforce)") }
  end
end
