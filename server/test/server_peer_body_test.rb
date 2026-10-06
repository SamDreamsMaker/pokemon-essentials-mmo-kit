require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# A body one client relays to another (a trade's escrow, a PvP team) is Marshal the
# receiver loads. With PEMK_PEER_CHECK on the server reads it (never loads it) and
# drops one naming a class outside the allow list; shadow only logs it.
class ServerPeerBodyTest < Minitest::Test
  W = PEMK::Wire

  # Something no party holds. The server never loads it, it only reads its name.
  class Stranger
    def initialize; @note = "x"; end
  end

  # Bytes as a real party dumps them: objects of a top-level class named Pokemon (made
  # for the dump only, so no other test sees it).
  def party_bytes(*extra)
    made = !Object.const_defined?(:Pokemon)
    Object.const_set(:Pokemon, Class.new { def initialize; @species = :PIKACHU; @moves = []; end }) if made
    Marshal.dump([Object.const_get(:Pokemon).new, *extra])
  ensure
    Object.send(:remove_const, :Pokemon) if made
  end

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    %i[monster_transfers monsters enforcement_events player_flags].each { |t| @db[t].delete rescue nil }
    @db[:accounts].delete
    @logs = Queue.new
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(check, classes: "")
    env = ENV.to_h.merge("PEMK_PEER_CHECK" => check, "PEMK_PEER_CLASSES" => classes,
                         "PEMK_ANOMALY_DETECTION" => "on")
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
    @server.start
    @port = @server.port
  end

  def logs
    out = []
    out << @logs.pop until @logs.empty?
    out
  end

  def send_env(s, e, body = nil)
    s.write(W.encode_split(e, body))
  end

  # -> [env, body] of the next frame of one of +types+.
  def recv_type(s, *types)
    Timeout.timeout(5) do
      loop do
        h = s.read(4)
        return nil if h.nil?

        dec = W.decode_envelope(s.read(h.unpack1("N")), false)
        return [dec[:env], dec[:body]] if types.include?(dec[:env][:type])
      end
    end
  end

  def login(email)
    s = TCPSocket.new("127.0.0.1", @port)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv_type(s, :register_ok, :register_err)
    send_env(s, { type: :login, email: email, password: "password1" })
    env, = recv_type(s, :login_ok)
    [s, env]
  end

  # Two players who agreed to trade.
  def pair
    a, la = login("pa@t.co")
    b, lb = login("pb@t.co")
    send_env(a, { type: :trade_invite, to: lb[:account_id], trade_id: "t1" })
    recv_type(b, :trade_invite)
    send_env(b, { type: :trade_accept, to: la[:account_id], trade_id: "t1" })
    recv_type(a, :trade_accept)
    [a, b, lb[:account_id], la]
  end

  def lock(from, to_id, body)
    send_env(from, { type: :trade_lock, to: to_id, trade_id: "t1" }, body)
  end

  def test_a_party_is_relayed
    start_server("on")
    a, b, bid, la = pair
    assert_equal "on", la[:peer_check]
    bytes = party_bytes
    lock(a, bid, bytes)
    env, body = recv_type(b, :trade_lock)
    assert_equal :trade_lock, env[:type]
    assert_equal bytes, body
  end

  def test_a_foreign_class_is_dropped_and_flagged
    start_server("on")
    a, b, bid, = pair
    lock(a, bid, party_bytes(Stranger.new))
    send_env(a, { type: :trade_offer, to: bid, trade_id: "t1", uid: 5 })
    env, = recv_type(b, :trade_lock, :trade_offer)
    assert_equal :trade_offer, env[:type], "the refused body never reached the partner"
    assert(logs.any? { |l| l.include?("REFUSED (class ServerPeerBodyTest::Stranger)") })
    Timeout.timeout(5) { sleep 0.05 until @db[:player_flags].where(kind: "peer_body").count == 1 }
  end

  def test_shadow_relays_and_logs
    start_server("shadow")
    a, b, bid, = pair
    lock(a, bid, Marshal.dump([Stranger.new]))
    env, = recv_type(b, :trade_lock)
    assert_equal :trade_lock, env[:type]
    assert(logs.any? { |l| l.include?("WOULD-REFUSE (class ServerPeerBodyTest::Stranger)") })
  end

  def test_off_relays_as_before
    start_server("off")
    a, b, bid, la = pair
    assert_equal "off", la[:peer_check]
    lock(a, bid, Marshal.dump([Stranger.new]))
    env, = recv_type(b, :trade_lock)
    assert_equal :trade_lock, env[:type]
    refute(logs.any? { |l| l.include?("REFUSE") })
  end

  # A game's own class in a Pokemon is added by the operator.
  def test_the_allow_list_takes_a_game_s_classes
    start_server("on", classes: "ServerPeerBodyTest::Stranger")
    a, b, bid, = pair
    lock(a, bid, Marshal.dump([Stranger.new]))
    env, = recv_type(b, :trade_lock)
    assert_equal :trade_lock, env[:type]
  end
end
