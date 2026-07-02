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

# Economy authority over the wire: :econ -> :econ_ack (canonical balance) or
# :econ_rej (rolled back to current), the canonical balance in login_ok, and
# per-account serialization through the mailbox.
class ServerEconTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:accounts].delete
    @server = PEMK::Server.new(logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def open_conn
    TCPSocket.new("127.0.0.1", @port)
  end

  def send_env(sock, env)
    sock.write(W.encode_split(env))
  end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def register(sock, email, pw)
    send_env(sock, { type: :register, email: email, password: pw })
    recv(sock)
  end

  def login(sock, email, pw)
    send_env(sock, { type: :login, email: email, password: pw })
    recv(sock)
  end

  def test_econ_ack_reject_and_login_snapshot
    c = open_conn
    register(c, "eco@t.co", "password1")
    lo = login(c, "eco@t.co", "password1")
    assert_equal :login_ok, lo[:type]
    assert_equal({}, lo[:econ] || {})
    assert_equal 0, lo[:econ_seq]

    send_env(c, { type: :econ, field: :money, value: 500, seq: 1 })
    ack = recv(c)
    assert_equal :econ_ack, ack[:type]
    assert_equal 500, ack[:value]
    assert_equal 1, ack[:seq]

    send_env(c, { type: :econ, field: :money, value: 1_000_000, seq: 2 }) # over cap
    rej = recv(c)
    assert_equal :econ_rej, rej[:type]
    assert_equal 500, rej[:value] # rolled back to the current balance
    c.close

    c2 = open_conn
    lo2 = login(c2, "eco@t.co", "password1")
    assert_equal({ money: 500 }, lo2[:econ])
    assert_equal 1, lo2[:econ_seq]
    c2.close
  end

  def test_mailbox_serializes_in_order
    c = open_conn
    register(c, "seq@t.co", "password1")
    login(c, "seq@t.co", "password1")
    3.times { |i| send_env(c, { type: :econ, field: :money, value: (i + 1) * 100, seq: i + 1 }) }
    acks = 3.times.map { recv(c) }
    assert_equal [1, 2, 3], acks.map { |a| a[:seq] }
    assert_equal [100, 200, 300], acks.map { |a| a[:value] }
    c.close
  end

  # Badges are just another economy field (:badges bitmask): they ride the same
  # :econ -> :econ_ack path and land in the login snapshot. This also proves the
  # real Config DERIVES the :badges cap into @economy_caps — a missing derivation
  # would reject the frame as :bad_field, not ack it.
  def test_badges_ride_the_econ_channel
    c = open_conn
    register(c, "badge@t.co", "password1")
    login(c, "badge@t.co", "password1")
    mask = 0b101   # badges 0 and 2 owned
    send_env(c, { type: :econ, field: :badges, value: mask, seq: 1 })
    ack = recv(c)
    assert_equal :econ_ack, ack[:type]
    assert_equal :badges, ack[:field]
    assert_equal mask, ack[:value]
    c.close

    c2 = open_conn
    lo = login(c2, "badge@t.co", "password1")
    assert_equal mask, lo[:econ][:badges]
    c2.close
  end

  # The bag rides a new :inv frame (absolute {Symbol=>Integer} snapshot) through the
  # SAME mailbox: server records + acks (never rejects), login carries inv_seq. Also
  # proves the real Config derived the inventory caps and the codec round-trips the
  # bag Hash as pure primitives.
  def test_inv_records_and_login_restores_the_bag
    c = open_conn
    register(c, "bag@t.co", "password1")
    lo = login(c, "bag@t.co", "password1")
    assert_equal 0, lo[:inv_seq]
    assert_nil lo[:inv]                       # unseeded: no bag shipped -> client keeps its blob bag

    send_env(c, { type: :inv, bag: { POTION: 5, GREAT_BALL: 2 }, seq: 1 })
    ack = recv(c)
    assert_equal :inv_ack, ack[:type]
    assert_equal 1, ack[:seq]
    assert_equal false, ack[:flagged]
    c.close

    c2 = open_conn
    lo2 = login(c2, "bag@t.co", "password1")
    assert_equal 1, lo2[:inv_seq]
    assert_equal({ POTION: 5, GREAT_BALL: 2 }, lo2[:inv])   # server-persistent: bag restored on login
    c2.close
  end
end
