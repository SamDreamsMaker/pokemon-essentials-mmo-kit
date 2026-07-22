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

# M4 Layer D D4 over the wire: a wild :battle_end_report opens a reward window (only for
# foes matching this connection's encounter mints); a following :money :econ delta gets
# a "battle:<n>" ledger reason within budget, "battle_suspect" beyond it; money with no
# window stays "unattributed".
class ServerRewardTest < Minitest::Test
  W = PEMK::Wire

  WORLD = Tempfile.new(["pemk_world", ".json"])
  WORLD.write(JSON.generate(
    "schema_version" => 2,
    "maps" => { "5" => { "name" => "R", "width" => 20, "height" => 20,
                         "encounters" => { "0" => { "Land" => { "step_chance" => 21, "slots" => [[100, "SPINARAK", 12, 12]] } } } } }
  ))
  WORLD.flush

  BATTLE = Tempfile.new(["pemk_battle", ".json"])
  BATTLE.write(JSON.generate(
    "schema_version" => 1,
    "caps" => {}, "natures" => {}, "types" => {}, "abilities" => [], "items" => {}, "moves" => {},
    "growth_rates" => { "Parabolic" => { "max_exp" => 1_059_860, "curve" => (1..100).map { |n| n * 1000 } } },
    "species" => { "SPINARAK" => { "species" => "SPINARAK", "form" => 0, "base_stats" => { "HP" => 40 },
                                   "base_exp" => 64, "growth_rate" => "Parabolic", "catch_rate" => 255 } }
  ))
  BATTLE.flush

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:economy_ledger].delete rescue nil
    @db[:economy_balances].delete rescue nil
    @db[:encounter_rolls].delete rescue nil
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

  def start_server(rewards: "shadow")
    env = ENV.to_h.merge("PEMK_WORLD" => WORLD.path, "PEMK_BATTLE_DATA" => BATTLE.path,
                         "PEMK_BATTLE_ENFORCE_ENCOUNTERS" => "on", "PEMK_BATTLE_ENFORCE_REWARDS" => rewards)
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

  def sync(c); send_env(c, { type: :ping, t: 1 }); assert_equal :pong, recv(c)[:type]; end

  # mint an encounter (stashes the mint) and return its grant (has the server pid).
  def mint(c)
    send_env(c, { type: :pos, map: 5, x: 3, y: 3 })
    send_env(c, { type: :encounter_req, map: 5, enctype: :Land, seq: 1 })
    r = recv(c); assert_equal :encounter_grant, r[:type]; r
  end

  def acct_id(email); @db[:accounts].where(email: email).get(:id); end
  def last_reason(aid); @db[:economy_ledger].where(account_id: aid, field: "money").order(Sequel.desc(:id)).get(:reason); end

  def test_login_advertises_reward_mode
    start_server(rewards: "shadow")
    _, lo = authed_conn("rw1@t.co")
    assert_equal "shadow", lo[:battle_enforce_rewards]
  end

  def test_money_after_a_reported_battle_is_attributed
    start_server
    c, = authed_conn("rw2@t.co")
    g = mint(c)
    send_env(c, { type: :battle_end_report, outcome: 1, foes: [{ pid: g[:pid] }] })  # won
    send_env(c, { type: :econ, field: :money, value: 700, seq: 1 })                  # +700 (Pay Day-ish)
    assert_equal :econ_ack, recv(c)[:type]
    assert_equal "battle:1", last_reason(acct_id("rw2@t.co"))
    refute(@logs.any? { |l| l.include?("SUSPECT") }, @logs.grep(/reward:/).inspect)
    c.close
  end

  def test_money_over_budget_is_logged_suspect_but_ledger_stays_clean
    start_server
    c, = authed_conn("rw3@t.co")
    g = mint(c)
    send_env(c, { type: :battle_end_report, outcome: 1, foes: [{ pid: g[:pid] }] })
    send_env(c, { type: :econ, field: :money, value: 500_000, seq: 1 })              # absurd for a wild win
    assert_equal :econ_ack, recv(c)[:type]                                           # detection-only: still acks
    assert_equal "battle:1", last_reason(acct_id("rw3@t.co"))                        # clean attribution, NOT "battle_suspect"
    assert(@logs.any? { |l| l.include?("SUSPECT money delta") }, @logs.grep(/reward:/).inspect)
    c.close
  end

  def test_money_without_a_battle_is_unattributed
    start_server
    c, = authed_conn("rw4@t.co")
    send_env(c, { type: :econ, field: :money, value: 3_000, seq: 1 })                # a shop sale
    assert_equal :econ_ack, recv(c)[:type]
    assert_equal "unattributed", last_reason(acct_id("rw4@t.co"))
    c.close
  end

  def test_battle_end_with_a_fabricated_foe_opens_no_window
    start_server
    c, = authed_conn("rw5@t.co")
    mint(c)
    send_env(c, { type: :battle_end_report, outcome: 1, foes: [{ pid: 999_999 }] })  # not a minted pid
    send_env(c, { type: :econ, field: :money, value: 700, seq: 1 })
    assert_equal :econ_ack, recv(c)[:type]
    assert_equal "unattributed", last_reason(acct_id("rw5@t.co"))                    # no window opened
    c.close
  end

  def test_off_mode_never_attributes
    start_server(rewards: "off")
    c, = authed_conn("rw6@t.co")
    g = mint(c)
    send_env(c, { type: :battle_end_report, outcome: 1, foes: [{ pid: g[:pid] }] })
    send_env(c, { type: :econ, field: :money, value: 700, seq: 1 })
    assert_equal :econ_ack, recv(c)[:type]
    assert_equal "unattributed", last_reason(acct_id("rw6@t.co"))
    c.close
  end

  def test_battle_end_requires_auth
    start_server
    c = open_conn
    send_env(c, { type: :battle_end_report, outcome: 1, foes: [{ pid: 1 }] })
    assert_nil recv(c, 2)
    c.close
  end
end
