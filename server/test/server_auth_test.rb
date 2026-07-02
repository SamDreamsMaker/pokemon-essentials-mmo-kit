require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"

root  = File.expand_path("..", __dir__)               # server/
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)

ENV["PEMK_BIND"] = "127.0.0.1"
ENV["PEMK_PORT"] = "0"
require "pemk"

# Black-box integration test of the auth-gate over real sockets: register / login
# (-> session token) / reconnect-with-token, bad credentials, the pre-auth gate
# dropping gameplay frames, and :ping allowed before auth.
class ServerAuthTest < Minitest::Test
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

  def send_env(sock, env, body = nil)
    sock.write(W.encode_split(env, body))
  end

  def recv_env(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def test_register_login_token_reconnect
    c = open_conn
    send_env(c, { type: :register, email: "red@t.co", password: "charizard1" })
    reg = recv_env(c)
    assert_equal :register_ok, reg[:type]
    account_id = reg[:account_id]
    assert_kind_of Integer, account_id

    send_env(c, { type: :register, email: "red@t.co", password: "different1" }) # same email
    assert_equal :register_err, recv_env(c)[:type]

    send_env(c, { type: :login, email: "red@t.co", password: "charizard1" })
    lo = recv_env(c)
    assert_equal :login_ok, lo[:type]
    assert_equal account_id, lo[:account_id]
    assert_equal 64, lo[:token].length
    token = lo[:token]
    c.close

    c2 = open_conn
    send_env(c2, { type: :auth, token: token })
    a = recv_env(c2)
    assert_equal :auth_ok, a[:type]
    assert_equal account_id, a[:account_id]
    c2.close
  end

  def test_bad_password_and_bad_token
    c = open_conn
    send_env(c, { type: :register, email: "blue@t.co", password: "blastoise1" })
    recv_env(c)
    send_env(c, { type: :login, email: "blue@t.co", password: "wrongpass1" })
    assert_equal :login_err, recv_env(c)[:type]
    c.close

    c2 = open_conn
    send_env(c2, { type: :auth, token: "deadbeefnope" })
    assert_equal :auth_err, recv_env(c2)[:type]
    c2.close
  end

  def test_ping_allowed_but_gameplay_dropped_pre_auth
    c = open_conn
    send_env(c, { type: :ping, t: 99 })
    pong = recv_env(c)
    assert_equal :pong, pong[:type]
    assert_equal 99, pong[:t]

    # a gameplay frame before auth -> the gate drops the connection
    send_env(c, { type: :pos, x: 1, y: 2 })
    assert_nil recv_env(c)
    c.close
  end
end
