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

# M4 Layer D D3 over the wire: a :catch_req is adjudicated against the STASHED D2
# encounter mint (species/level/IVs the server itself minted); the server rolls the
# shakes. A Master Ball is unconditional, making the happy path deterministic. A
# successful catch consumes the mint (a second catch of the same mint fail-opens).
class ServerCatchTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 2,
    "maps" => { "5" => { "name" => "Route", "width" => 20, "height" => 20,
                         "encounters" => { "0" => {
                           "Land" => { "step_chance" => 21, "slots" => [[100, "SPINARAK", 12, 12]] }
                         } } } }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  BATTLE.write(JSON.generate(
    "schema_version" => 1,
    "caps" => {}, "natures" => {}, "growth_rates" => {}, "types" => {}, "abilities" => [],
    "items" => {}, "moves" => {},
    "species" => { "SPINARAK" => { "species" => "SPINARAK", "form" => 0,
                                   "base_stats" => { "HP" => 40 }, "catch_rate" => 255 } }
  ))
  BATTLE.flush

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

  def start_server(catches: "on", encounters: "on")
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path,
                         "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => encounters,
                         "PEMK_BATTLE_ENFORCE_CATCHES" => catches)
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

  def sync(c)
    send_env(c, { type: :ping, t: 1 })
    assert_equal :pong, recv(c)[:type]
  end

  # mint an encounter on this conn (stashes it server-side) and return the grant.
  def mint(c, seq: 1)
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    send_env(c, { type: :encounter_req, map: 5, enctype: :Land, seq: seq })
    r = recv(c)
    assert_equal :encounter_grant, r[:type]
    r
  end

  def catch_req(c, grant, ball:, seq:, hp: 10)
    send_env(c, { type: :catch_req, species: grant[:species], level: grant[:level],
                  ball: ball, hp_current: hp, status: :NONE, claimed_rate: 255,
                  dex_owned: 0, charm: false, seq: seq })
    recv(c)
  end

  def test_login_advertises_catch_mode
    start_server(catches: "shadow")
    _, lo = authed_conn("ct1@t.co")
    assert_equal "shadow", lo[:battle_enforce_catches]
  end

  def test_master_ball_catch_is_granted_and_consumes_the_mint
    start_server
    c, = authed_conn("ct2@t.co")
    g = mint(c)
    r = catch_req(c, g, ball: :MASTERBALL, seq: 2)
    assert_equal :catch_verdict, r[:type]
    assert_equal 2, r[:seq]
    assert_equal 4, r[:shakes]
    assert_equal false, r[:critical]
    assert(@logs.any? { |l| l.include?("CAUGHT") }, @logs.grep(/catch:/).inspect)

    # the mint is consumed: a second catch of the same identity fail-opens
    r2 = catch_req(c, g, ball: :MASTERBALL, seq: 3)
    assert_equal :catch_deny, r2[:type]
    assert_equal "no_encounter", r2[:reason]
    c.close
  end

  def test_catch_without_a_mint_denies_no_encounter
    start_server
    c, = authed_conn("ct3@t.co")
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    send_env(c, { type: :catch_req, species: "SPINARAK", level: 12, ball: :MASTERBALL,
                  hp_current: 1, status: :NONE, seq: 1 })
    r = recv(c)
    assert_equal :catch_deny, r[:type]
    assert_equal "no_encounter", r[:reason]
    c.close
  end

  def test_failed_shakes_keep_the_mint_for_a_retry
    start_server
    c, = authed_conn("ct4@t.co")
    g = mint(c)
    # a plain ball at full HP will USUALLY fail (p(caught) = (53335/65536)^4 ≈ 0.44), but
    # either way the reply is a verdict; when it fails the mint must still be there. Retry
    # until a failure is observed (bounded), then re-catch with a Master Ball.
    failed = false
    20.times do |i|
      r = catch_req(c, g, ball: :POKEBALL, seq: 10 + i, hp: 35)
      assert_equal :catch_verdict, r[:type]
      if r[:shakes] < 4
        failed = true
        break
      end
      g = mint(c, seq: 100 + i)   # that one was caught (mint consumed) — mint a fresh one
    end
    if failed
      r = catch_req(c, g, ball: :MASTERBALL, seq: 60)   # mint still there after a failure
      assert_equal :catch_verdict, r[:type]
      assert_equal 4, r[:shakes]
    end
    c.close
  end

  def test_off_mode_denies_not_enforcing
    start_server(catches: "off")
    c, = authed_conn("ct5@t.co")
    g = mint(c)
    r = catch_req(c, g, ball: :MASTERBALL, seq: 2)
    assert_equal :catch_deny, r[:type]
    assert_equal "not_enforcing", r[:reason]
    c.close
  end

  def test_shadow_report_logs_server_would
    start_server(catches: "shadow")
    c, = authed_conn("ct6@t.co")
    mint(c)
    send_env(c, { type: :catch_report, species: "SPINARAK", level: 12, ball: :POKEBALL,
                  hp_current: 35, status: :NONE, claimed_rate: 255, shakes: 3,
                  dex_owned: 0, charm: false })
    sync(c)
    assert(@logs.any? { |l| l.include?("catch:") && l.include?("client_shakes=3") && l.include?("server_would=") },
           @logs.grep(/catch:/).inspect)
    c.close
  end

  def test_catch_req_requires_auth
    start_server
    c = open_conn
    send_env(c, { type: :catch_req, species: "SPINARAK", level: 12, ball: :MASTERBALL, seq: 1 })
    assert_nil recv(c, 2)
    c.close
  end
end
