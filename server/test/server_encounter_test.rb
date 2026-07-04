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

# M4 Layer D D2 (shadow) over the wire: the client reports the wild encounter it rolled
# locally; the server audits it against the Layer A encounter tables (world.json) and logs
# suspicious ones + what it would mint. Fire-and-forget, so tests sync with a ping/pong
# (frames on one connection are processed in order).
class ServerEncounterTest < Minitest::Test
  W = PEMK::Wire

  FIXTURE = Tempfile.new(["pemk_world", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 2,
    "maps" => { "5" => { "name" => "Route", "width" => 20, "height" => 20,
                         "encounters" => { "0" => {
                           "Land" => { "step_chance" => 21, "slots" => [[50, "PIDGEY", 3, 5], [50, "RATTATA", 2, 4]] }
                         } } } }
  ))
  FIXTURE.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(encounter_mode: "shadow")
    env = ENV.to_h.merge("PEMK_WORLD" => FIXTURE.path, "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => encounter_mode)
    @server = PEMK::Server.new(config: PEMK::Config.new(env: env), logger: ->(m) { @logs << m })
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

  # send a frame then a ping, and wait for the pong — guarantees the frame was handled.
  def sync(c)
    send_env(c, { type: :ping, t: 1 })
    r = recv(c)
    assert_equal :pong, r[:type]
  end

  def enc_log; @logs.grep(/encounter:/); end

  def test_login_advertises_encounter_mode
    start_server(encounter_mode: "shadow")
    _, lo = authed_conn("ec1@t.co")
    assert_equal "shadow", lo[:battle_enforce_encounters]
  end

  def test_legal_encounter_logs_ok_with_would_mint
    start_server
    c, = authed_conn("ec2@t.co")
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })   # player is on map 5
    send_env(c, { type: :encounter_report, map: 5, enctype: :Land, species: :PIDGEY, level: 4 })
    sync(c)
    line = enc_log.find { |l| l.include?("PIDGEY") }
    refute_nil line, enc_log.inspect
    assert_includes line, "ok"
    assert_includes line, "server_would="
    refute_includes line, "SUSPECT"
    c.close
  end

  def test_species_not_in_table_is_suspect
    start_server
    c, = authed_conn("ec3@t.co")
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    send_env(c, { type: :encounter_report, map: 5, enctype: :Land, species: :MEWTWO, level: 70 })
    sync(c)
    assert(enc_log.any? { |l| l.include?("SUSPECT species-not-in-table") && l.include?("MEWTWO") }, enc_log.inspect)
    c.close
  end

  def test_wrong_map_is_suspect
    start_server
    c, = authed_conn("ec4@t.co")
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })   # server-known position is map 5
    send_env(c, { type: :encounter_report, map: 6, enctype: :Land, species: :PIDGEY, level: 4 })  # claims map 6
    sync(c)
    assert(enc_log.any? { |l| l.include?("SUSPECT wrong-map(on 5)") }, enc_log.inspect)
    c.close
  end

  def test_encounter_report_requires_auth
    start_server
    c = open_conn
    send_env(c, { type: :encounter_report, map: 5, enctype: :Land, species: :PIDGEY, level: 4 })
    assert_nil recv(c, 2)   # pre-auth -> dropped, connection closed
    c.close
  end
end
