require "minitest/autorun"
require "socket"
require "timeout"
require "sequel"
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

# M4 Layer C server-minted pickups over the wire: :pickup_req -> :pickup_grant on a
# first valid pickup, :pickup_deny (already_taken / too_far / no_object) otherwise,
# judged against the player's SERVER-tracked tile; and the pickup_enforce flag in the
# login snapshot. A fixture world (POTION at map 5 (12,8)) is passed via a per-test
# Config so it never leaks into the other server tests.
class ServerPickupTest < Minitest::Test
  W = PEMK::Wire

  # Kept in a constant so the Tempfile isn't GC'd/unlinked mid-run.
  FIXTURE = Tempfile.new(["pemk_world", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 2,
    "maps" => { "5" => { "name" => "T", "width" => 40, "height" => 30,
                         "objects" => [{ "kind" => "item", "item" => "POTION", "x" => 12, "y" => 8, "event_id" => 1 }] } }
  ))
  FIXTURE.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(pickup_enforce: false)
    env = ENV.to_h.merge("PEMK_WORLD" => FIXTURE.path, "PEMK_PICKUP_ENFORCE" => (pickup_enforce ? "on" : "off"))
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(_m) {})
    @server.start
    @port = @server.port
  end

  def open_conn; TCPSocket.new("127.0.0.1", @port); end
  def send_env(sock, env); sock.write(W.encode_split(env)); end

  def recv(sock, timeout = 5)
    Timeout.timeout(timeout) do
      hdr = sock.read(4)
      return nil if hdr.nil?

      W.decode_envelope(sock.read(hdr.unpack1("N")), false)[:env]
    end
  end

  def authed_conn(email)
    c = open_conn
    send_env(c, { type: :register, email: email, password: "password1" }); recv(c)
    send_env(c, { type: :login, email: email, password: "password1" })
    [c, recv(c)]
  end

  def test_first_pickup_grants_then_repeat_denies_already_taken
    start_server
    c, = authed_conn("pk1@t.co")
    send_env(c, { type: :pos, map: 5, x: 12, y: 7 })   # server last_pos adjacent to the item
    send_env(c, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 12, y: 8, seq: 1 })
    r = recv(c)
    assert_equal :pickup_grant, r[:type]
    assert_equal 1, r[:seq]
    assert_equal "POTION", r[:item].to_s

    send_env(c, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 12, y: 8, seq: 2 })
    r2 = recv(c)
    assert_equal :pickup_deny, r2[:type]
    assert_equal 2, r2[:seq]
    assert_equal "already_taken", r2[:reason]
    c.close
  end

  def test_pickup_far_from_player_denies_too_far
    start_server
    c, = authed_conn("pk2@t.co")
    send_env(c, { type: :pos, map: 5, x: 1, y: 1 })    # far from the item at (12,8)
    send_env(c, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 12, y: 8, seq: 1 })
    r = recv(c)
    assert_equal :pickup_deny, r[:type]
    assert_equal "too_far", r[:reason]
    c.close
  end

  def test_pickup_of_a_nonexistent_object_denies_no_object
    start_server
    c, = authed_conn("pk3@t.co")
    send_env(c, { type: :pos, map: 5, x: 1, y: 1 })
    send_env(c, { type: :pickup_req, kind: :item, item: :POTION, map: 5, x: 1, y: 1, seq: 1 })  # nothing at (1,1)
    r = recv(c)
    assert_equal :pickup_deny, r[:type]
    assert_equal "no_object", r[:reason]
    c.close
  end

  def test_login_advertises_pickup_enforce_flag
    start_server(pickup_enforce: false)
    _, lo = authed_conn("pk4@t.co")
    assert_equal :login_ok, lo[:type]
    assert_equal false, lo[:pickup_enforce]
  end

  def test_login_advertises_enforce_on
    start_server(pickup_enforce: true)
    _, lo = authed_conn("pk5@t.co")
    assert_equal true, lo[:pickup_enforce]
  end
end
