require "minitest/autorun"

root  = File.expand_path("..", __dir__)
lib   = File.join(root, "lib")
proto = File.expand_path("../protocol", root)
$LOAD_PATH.unshift(lib)   unless $LOAD_PATH.include?(lib)
$LOAD_PATH.unshift(proto) unless $LOAD_PATH.include?(proto)
require "pemk"

# The atomic ownership swap — the single security invariant of trading.
class TradesTest < Minitest::Test
  MON_CAPS = { uid_req_max: 64, party_max: 6, level_max: 100, trade_max: 1 }.freeze

  def setup
    @db = PEMK::DB.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete
    @db[:monsters].delete
    @db[:accounts].delete
    @a = @db[:accounts].insert(email: "a@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @b = @db[:accounts].insert(email: "b@t.co", password_hash: "x", status: "active", created_at: Time.now)
    @trades = PEMK::Trades.new(@db)
    @mon    = PEMK::Monsters.new(@db, MON_CAPS)
  end

  def teardown
    @db&.disconnect
  end

  def mint(owner, species, nonce, flagged: false, status: "active")
    @db[:monsters].insert(owner_account_id: owner, issuer_account_id: owner, client_nonce: nonce,
                          species: species, level_at_issue: 5, personal_id: 1, egg_at_issue: false,
                          status: status, flagged: flagged)
  end

  def owner(uid)
    @db[:monsters].where(id: uid).get(:owner_account_id)
  end

  def test_happy_one_for_one_flips_both_owners
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    st, = @trades.execute_trade("t1", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal :ok, st
    assert_equal @b, owner(ua)
    assert_equal @a, owner(ub)
    assert_equal 2, @db[:monster_transfers].where(trade_id: "t1").count
  end

  def test_abort_when_seller_does_not_own
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    # each side offers a uid it does NOT own -> both CAS 0 rows -> whole trade aborts
    st, reason = @trades.execute_trade("t2", a: @a, b: @b, a_gives: [ub], b_gives: [ua])
    assert_equal :abort, st
    assert_equal :ownership, reason
    assert_equal @a, owner(ua)               # unchanged
    assert_equal @b, owner(ub)
    assert_equal 0, @db[:monster_transfers].count
  end

  def test_second_trade_of_an_already_traded_mon_aborts_wholesale
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    uc = mint(@b, "MEW", 3)
    @trades.execute_trade("t3", a: @a, b: @b, a_gives: [ua], b_gives: [ub])  # ua -> B
    st, = @trades.execute_trade("t4", a: @a, b: @b, a_gives: [ua], b_gives: [uc])  # A no longer owns ua
    assert_equal :abort, st
    assert_equal @b, owner(uc)               # whole trade rolled back
  end

  def test_flagged_mon_cannot_be_traded
    ua = mint(@a, "PIKACHU", 1, flagged: true)
    ub = mint(@b, "EEVEE", 2)
    st, = @trades.execute_trade("t5", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal :abort, st
    assert_equal @a, owner(ua)
    assert_equal @b, owner(ub)
  end

  def test_replay_is_idempotent_no_double_swap
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    @trades.execute_trade("t6", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    st, = @trades.execute_trade("t6", a: @a, b: @b, a_gives: [ua], b_gives: [ub])   # replay same trade_id
    assert_equal :ok_replay, st
    assert_equal 2, @db[:monster_transfers].where(trade_id: "t6").count             # not doubled
    assert_equal @b, owner(ua)                                                      # not swapped back
  end

  def test_evictions_positive_list
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    @trades.execute_trade("t7", a: @a, b: @b, a_gives: [ua], b_gives: [ub])
    assert_equal [ua], @mon.evictions(@a)    # A traded ua away, no longer owns it
    assert_equal [ub], @mon.evictions(@b)
  end

  def test_a_returned_mon_is_not_evicted
    ua = mint(@a, "PIKACHU", 1)
    ub = mint(@b, "EEVEE", 2)
    @trades.execute_trade("t8", a: @a, b: @b, a_gives: [ua], b_gives: [ub])  # ua->B, ub->A
    @trades.execute_trade("t9", a: @a, b: @b, a_gives: [ub], b_gives: [ua])  # ua BACK to A, ub back to B
    # ua was traded away once but is owned by A again -> current-owner check excludes it.
    refute_includes @mon.evictions(@a), ua
    refute_includes @mon.evictions(@b), ub
  end
end
