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

# Trading over the wire: the :trade_commit rendezvous + cross-check + atomic swap +
# per-recipient :trade_result, and mon_evict in login_ok.
class ServerTradeTest < Minitest::Test
  W = PEMK::Wire

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete
    @db[:monsters].delete
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

  def send_env(s, e)
    s.write(W.encode_split(e))
  end

  def recv(s, t = 5)
    Timeout.timeout(t) do
      h = s.read(4)
      return nil if h.nil?

      W.decode_envelope(s.read(h.unpack1("N")), false)[:env]
    end
  end

  def reg_login(s, email)
    send_env(s, { type: :register, email: email, password: "password1" })
    recv(s)
    send_env(s, { type: :login, email: email, password: "password1" })
    recv(s)
  end

  def mint(owner, species, nonce)
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: species, level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: "active", flagged: false)
  end

  def test_full_trade_swaps_and_login_evicts
    a = open_conn; acct_a = reg_login(a, "ta@t.co")[:account_id]
    b = open_conn; acct_b = reg_login(b, "tb@t.co")[:account_id]
    ua = mint(acct_a, "PIKACHU", 1)
    ub = mint(acct_b, "EEVEE", 2)

    send_env(a, { type: :trade_commit, trade_id: "T1", partner: acct_b, give: [ua], recv: [ub] })
    send_env(b, { type: :trade_commit, trade_id: "T1", partner: acct_a, give: [ub], recv: [ua] })
    ra = recv(a)
    rb = recv(b)
    assert_equal true, ra[:ok]
    assert_equal [ub], ra[:recv]
    assert_equal [ua], ra[:gave]
    assert_equal true, rb[:ok]
    assert_equal acct_b, @db[:monsters].where(id: ua).get(:owner_account_id)
    assert_equal acct_a, @db[:monsters].where(id: ub).get(:owner_account_id)
    a.close
    b.close

    a2 = open_conn
    send_env(a2, { type: :login, email: "ta@t.co", password: "password1" })
    lo = recv(a2)
    assert_equal [ua], lo[:mon_evict]     # A traded ua away -> evicted at login
    a2.close
  end

  def test_cross_check_mismatch_rejects_both_no_swap
    a = open_conn; acct_a = reg_login(a, "ta@t.co")[:account_id]
    b = open_conn; acct_b = reg_login(b, "tb@t.co")[:account_id]
    ua = mint(acct_a, "PIKACHU", 1)
    ub = mint(acct_b, "EEVEE", 2)

    send_env(a, { type: :trade_commit, trade_id: "T2", partner: acct_b, give: [ua], recv: [ub] })
    send_env(b, { type: :trade_commit, trade_id: "T2", partner: 999_999, give: [ub], recv: [ua] }) # wrong partner
    ra = recv(a)
    recv(b)
    assert_equal false, ra[:ok]
    assert_equal "terms", ra[:reason]
    assert_equal acct_a, @db[:monsters].where(id: ua).get(:owner_account_id)   # untouched
    a.close
    b.close
  end
end
