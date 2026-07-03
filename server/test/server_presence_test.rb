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

# Zone-scoped presence: same-map players see each other's position (stamped with
# the server-trusted account id, not a client-claimed id); different maps stay
# isolated; a disconnect fans a :leave to same-map peers.
class ServerPresenceTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
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

  def send_env(sock, env)
    sock.write(W.encode_split(env))
  end

  def recv_env(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def refute_receives(sock, timeout = 0.5)
    assert_raises(Timeout::Error) { recv_env(sock, timeout) }
  end

  def open_authed(user, pw)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, email: "#{user}@t.co", password: pw })
    recv_env(c)
    send_env(c, { type: :login, email: "#{user}@t.co", password: pw })
    [c, recv_env(c)[:account_id]]
  end

  def test_same_map_players_see_each_other_with_server_identity
    a, a_id = open_authed("Alice", "passwordA1")
    b, b_id = open_authed("Bobby", "passwordB1")

    send_env(a, { type: :pos, map: 5, x: 1, y: 1, id: 999_999 }) # a alone; spoofed id ignored
    send_env(b, { type: :pos, map: 5, x: 2, y: 2 })              # -> a hears b

    from_b = recv_env(a)
    assert_equal :pos, from_b[:type]
    assert_equal b_id, from_b[:id]
    assert_equal 5, from_b[:map]

    send_env(a, { type: :pos, map: 5, x: 3, y: 3 })              # -> b hears a
    from_a = recv_env(b)
    assert_equal a_id, from_a[:id]
    assert_equal 3, from_a[:x]

    a.close
    b.close
  end

  def test_different_maps_do_not_cross
    a, = open_authed("Amap", "passwordA1")
    send_env(a, { type: :pos, map: 5, x: 1, y: 1 })

    c, = open_authed("Cmap", "passwordC1")
    send_env(c, { type: :pos, map: 9, x: 1, y: 1 })

    refute_receives(a) # map 5 hears nothing from map 9
    a.close
    c.close
  end

  def test_disconnect_broadcasts_leave
    a, = open_authed("Ayla", "passwordA1")
    b, b_id = open_authed("Bill", "passwordB1")
    send_env(a, { type: :pos, map: 7, x: 1, y: 1 })
    send_env(b, { type: :pos, map: 7, x: 2, y: 2 })
    recv_env(a) # drain b's pos

    b.close
    left = recv_env(a)
    assert_equal :leave, left[:type]
    assert_equal b_id, left[:id]
    a.close
  end
end
