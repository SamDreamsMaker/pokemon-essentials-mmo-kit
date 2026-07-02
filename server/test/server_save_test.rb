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

# Save-store integration: a save round-trips through Postgres (login returns it as
# an opaque body on the next session), and a hostile save body is stored verbatim
# WITHOUT the server ever Marshal.load'ing it (the _load gadget never fires).
class ServerSaveTest < Minitest::Test
  W = PEMK::Wire

  # If the server ever deserialized a save body, this gadget's _load would flip
  # the global. It must stay false.
  class Boom
    def self._load(_s)
      $pemk_srv_boom = true
      allocate
    end

    def _dump(_l)
      "x"
    end
  end

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

  def send_env(sock, env, body = nil)
    sock.write(W.encode_split(env, body))
  end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)
    end
  end

  def register(sock, user, pw)
    send_env(sock, { type: :register, username: user, password: pw, email: "#{user}@t.co" })
    recv(sock)
  end

  def login(sock, user, pw)
    send_env(sock, { type: :login, username: user, password: pw })
    recv(sock)
  end

  def wait_until(timeout = 3)
    deadline = Time.now + timeout
    loop do
      value = yield
      return value if value
      raise "timeout waiting" if Time.now > deadline

      sleep 0.05
    end
  end

  def test_save_persists_and_reloads_as_body
    c = open_conn
    assert_equal :register_ok, register(c, "Nate", "hoennrules1")[:env][:type]
    lo = login(c, "Nate", "hoennrules1")
    assert_equal :login_ok, lo[:env][:type]
    assert_nil lo[:body], "a brand-new account has no save"
    account_id = lo[:env][:account_id]

    blob = Marshal.dump({ party: [1, 2, 3], money: 5000, name: "Réd" })
    send_env(c, { type: :save, trainer_id: 42 }, blob)
    wait_until { @db[:characters].where(account_id: account_id).get(:save_blob) }
    c.close

    c2 = open_conn
    lo2 = login(c2, "Nate", "hoennrules1")
    assert_equal :login_ok, lo2[:env][:type]
    assert_equal blob, lo2[:body], "login returns the stored save as an opaque body"
    c2.close
  end

  def test_hostile_save_body_stored_but_never_deserialized
    c = open_conn
    register(c, "Cynthia", "garchomp11")
    account_id = login(c, "Cynthia", "garchomp11")[:env][:account_id]

    $pemk_srv_boom = false
    evil = Marshal.dump(Boom.new)
    send_env(c, { type: :save }, evil)
    stored = wait_until { @db[:characters].where(account_id: account_id).get(:save_blob) }

    assert_equal false, $pemk_srv_boom, "server must not Marshal.load a save body"
    assert_equal evil, stored.to_s, "hostile bytes stored verbatim"
    c.close
  end
end
