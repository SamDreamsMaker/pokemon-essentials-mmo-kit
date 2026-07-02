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

# Server relays authenticated addressed frames (challenge / battle stream) to the
# :to account only, stamping the server-trusted :from and preserving the opaque
# body (a battle team). Offline / self targets are dropped.
class ServerRoutingTest < Minitest::Test
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

  def send_env(sock, env, body = nil)
    sock.write(W.encode_split(env, body))
  end

  def recv(sock, timeout = 2)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  def refute_receives(sock, timeout = 0.5)
    assert_raises(Timeout::Error) { recv(sock, timeout) }
  end

  def open_authed(user, pw)
    c = TCPSocket.new("127.0.0.1", @port)
    send_env(c, { type: :register, username: user, password: pw, email: "#{user}@t.co" })
    recv(c)
    send_env(c, { type: :login, username: user, password: pw })
    [c, recv(c)[:env][:account_id]]
  end

  def test_challenge_routed_with_server_stamped_from
    a, a_id = open_authed("Chal", "passwordA1")
    b, b_id = open_authed("Ceed", "passwordB1")

    send_env(a, { type: :challenge, to: b_id, from: 12_345, name: "Chal" }) # spoofed :from ignored
    m = recv(b)
    assert_equal :challenge, m[:env][:type]
    assert_equal a_id, m[:env][:from]
    assert_equal b_id, m[:env][:to]

    a.close
    b.close
  end

  def test_battle_team_body_preserved
    a, a_id = open_authed("Aaaa", "passwordA1")
    b, b_id = open_authed("Bbbb", "passwordB1")

    body = Marshal.dump([{ species: :PIKACHU, level: 5 }])
    send_env(a, { type: :battle_team, to: b_id, name: "A" }, body)
    m = recv(b)
    assert_equal :battle_team, m[:env][:type]
    assert_equal a_id, m[:env][:from]
    assert_equal body, m[:body]

    a.close
    b.close
  end

  def test_addressed_to_offline_is_dropped
    a, = open_authed("Solo", "passwordA1")
    send_env(a, { type: :challenge, to: 999_999 }) # nobody online with that id
    refute_receives(a)
    a.close
  end
end
