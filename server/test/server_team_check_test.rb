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

# M4 Layer D D1 over the wire: the client reports its full-stat team as PRIMITIVES in
# the envelope (never a Marshal blob); the server audits legality against a battle_data
# fixture and logs illegal teams (detection-only), always acking with the legality flag.
class ServerTeamCheckTest < Minitest::Test
  W = PEMK::Wire

  FIXTURE = Tempfile.new(["pemk_battle", ".json"])
  FIXTURE.write(JSON.generate(
    "schema_version" => 1,
    "caps"    => { "max_level" => 100, "iv_stat_limit" => 31, "ev_limit" => 510, "ev_stat_limit" => 252, "no_vitamin_ev_cap" => true },
    "natures" => { "ADAMANT" => [["ATTACK", 10], ["SPECIAL_ATTACK", -10]] },
    "growth_rates" => {}, "types" => {},
    "abilities" => ["OVERGROW"],
    "items"   => {},
    "moves"   => { "TACKLE" => { "power" => 40 }, "EARTHQUAKE" => { "power" => 100 } },
    "species" => {
      "BULBASAUR" => { "species" => "BULBASAUR", "form" => 0, "abilities" => ["OVERGROW"], "hidden_abilities" => [],
                       "level_up_moves" => [[1, "TACKLE"], [3, "GROWL"]], "tutor_moves" => [], "egg_moves" => [],
                       "prev_species" => nil, "minimum_level" => 1, "base_stats" => { "HP" => 45 } }
    }
  ))
  FIXTURE.flush

  IVS = { "HP" => 31, "ATTACK" => 31, "DEFENSE" => 31, "SPECIAL_ATTACK" => 31, "SPECIAL_DEFENSE" => 31, "SPEED" => 31 }.freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:pickups].delete rescue nil
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil
    @db[:accounts].delete   # cascades to the rest
    @logs = []
  end

  def teardown
    @server&.stop
    @db&.disconnect
  end

  def start_server(team_mode: "shadow")
    env = ENV.to_h.merge("PEMK_BATTLE_DATA" => FIXTURE.path, "PEMK_BATTLE_ENFORCE_TEAMS" => team_mode)
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

  def mon(moves)
    { "species" => "BULBASAUR", "level" => 50, "ivs" => IVS, "evs" => {},
      "moves" => moves, "ability" => "OVERGROW", "nature" => "ADAMANT", "item" => nil }
  end

  def test_login_advertises_team_enforce_mode
    start_server(team_mode: "shadow")
    _, lo = authed_conn("tm1@t.co")
    assert_equal "shadow", lo[:battle_enforce_teams]
  end

  def test_legal_team_acks_legal_and_logs_nothing
    start_server
    c, = authed_conn("tm2@t.co")
    send_env(c, { type: :team_check, team: [mon(["TACKLE"])], seq: 1 })
    r = recv(c)
    assert_equal :team_ack, r[:type]
    assert_equal 1, r[:seq]
    assert_equal true, r[:legal]
    refute(@logs.any? { |l| l.include?("illegal team") }, @logs.grep(/team:/).inspect)
    c.close
  end

  def test_illegal_team_acks_illegal_and_logs_would_reject
    start_server(team_mode: "shadow")
    c, = authed_conn("tm3@t.co")
    send_env(c, { type: :team_check, team: [mon(["EARTHQUAKE"])], seq: 7 })   # known move, not learnable
    r = recv(c)
    assert_equal :team_ack, r[:type]
    assert_equal 7, r[:seq]
    assert_equal false, r[:legal]
    assert(@logs.any? { |l| l.include?("WOULD-REJECT") && l.include?("illegal_move:EARTHQUAKE") }, @logs.grep(/team:/).inspect)
    c.close
  end

  def test_team_check_requires_auth
    start_server
    c = open_conn
    send_env(c, { type: :team_check, team: [mon(["TACKLE"])], seq: 1 })   # pre-auth -> dropped
    assert_nil recv(c, 2)   # connection closed, no ack
    c.close
  end
end
