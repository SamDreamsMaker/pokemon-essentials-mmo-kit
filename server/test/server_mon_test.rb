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

# Monster UIDs over the wire: :uid_req -> :uid_grant (idempotent across a
# reconnect), :mon_party -> :mon_ack, foreign-uid flagging, mon_seq in login_ok.
class ServerMonTest < Minitest::Test
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

  def register_login(sock, email)
    send_env(sock, { type: :register, email: email, password: "password1" })
    recv(sock)
    send_env(sock, { type: :login, email: email, password: "password1" })
    recv(sock)
  end

  def test_uid_mint_roundtrip_idempotent_across_reconnect
    c = open_conn
    lo = register_login(c, "mon@t.co")
    assert_equal 0, lo[:mon_seq]

    mons = [{ tmp: 4242, species: :PIKACHU, level: 12, pid: 99, egg: false }]
    send_env(c, { type: :uid_req, seq: 1, mons: mons })
    grant = recv(c)
    assert_equal :uid_grant, grant[:type]
    assert_equal 4242, grant[:grants][0][:tmp]
    uid = grant[:grants][0][:uid]
    assert_kind_of Integer, uid
    c.close

    # Reconnect (client seq resets to 0 -> irrelevant) and replay the SAME request:
    # the persisted-nonce dedup returns the SAME uid, no second row.
    c2 = open_conn
    send_env(c2, { type: :login, email: "mon@t.co", password: "password1" })
    recv(c2)
    send_env(c2, { type: :uid_req, seq: 1, mons: mons })
    replay = recv(c2)
    assert_equal uid, replay[:grants][0][:uid]
    assert_equal 1, @db[:monsters].count
    c2.close
  end

  def test_party_projection_flags_foreign_uid
    a = open_conn
    register_login(a, "victim@t.co")
    send_env(a, { type: :uid_req, seq: 1, mons: [{ tmp: 7, species: :MEW, level: 50, pid: 1, egg: false }] })
    uid = recv(a)[:grants][0][:uid]
    send_env(a, { type: :mon_party, seq: 1, mons: [{ uid: uid, species: :MEW, level: 50 }] })
    ack = recv(a)
    assert_equal :mon_ack, ack[:type]
    assert_equal false, ack[:flagged]
    a.close

    # A second account projecting the first account's uid = the copied-save case.
    b = open_conn
    register_login(b, "cloner@t.co")
    send_env(b, { type: :mon_party, seq: 1, mons: [{ uid: uid, species: :MEW, level: 50 }] })
    ack_b = recv(b)
    assert_equal true, ack_b[:flagged]
    assert_equal true, @db[:monsters].where(id: uid).get(:flagged)
    b.close

    # And the victim's next login carries its mon_seq high-water.
    a2 = open_conn
    send_env(a2, { type: :login, email: "victim@t.co", password: "password1" })
    assert_equal 1, recv(a2)[:mon_seq]
    a2.close
  end
end
