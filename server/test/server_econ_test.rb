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
end
