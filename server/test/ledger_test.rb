require "minitest/autorun"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/ledger"

# Economy ledger: absolute-value apply, cap validation, gap-safe idempotency by
# ledger-row existence, materialized balance, login snapshot.
class LedgerTest < Minitest::Test
  CAPS = { money: 999_999, coins: 99_999, battle_points: 9_999, soot: 9_999, badges: (1 << 63) - 1 }.freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:accounts].delete
    @acct = @db[:accounts].insert(email: "led@x.co", password_hash: "x", status: "active", created_at: Time.now)
    @led = PEMK::Ledger.new(@db, CAPS)
  end

  def teardown
    @db&.disconnect
  end

  def test_apply_sets_absolute_balance
    assert_equal [:ack, 500], @led.apply_econ(@acct, :money, 500, 1)
    assert_equal 500, @led.current(@acct, :money)
    assert_equal [:ack, 800], @led.apply_econ(@acct, :money, 800, 2)
    assert_equal 800, @led.current(@acct, :money)
  end

  def test_replayed_seq_is_a_dup_reacking_recorded_value
    assert_equal [:ack, 500], @led.apply_econ(@acct, :money, 500, 1)
    # same seq, different value -> not re-applied; re-ACK the value on record (500)
    assert_equal [:dup, 500], @led.apply_econ(@acct, :money, 999, 1)
    assert_equal 500, @led.current(@acct, :money)
  end

  def test_a_new_lower_seq_still_applies_gap_safe
    @led.apply_econ(@acct, :money, 700, 5)
    # seq 3 < 5 but its row does not exist -> applied (row-existence, not high-water)
    assert_equal [:ack, 600], @led.apply_econ(@acct, :money, 600, 3)
  end

  def test_cap_and_negative_rejected
    assert_equal [:rej, 0, :cap], @led.apply_econ(@acct, :money, 1_000_000, 1)
    assert_equal [:rej, 0, :cap], @led.apply_econ(@acct, :money, -5, 2)
    assert_equal 0, @led.current(@acct, :money)
  end

  def test_unknown_field_rejected
    assert_equal :bad_field, @led.apply_econ(@acct, :gold, 5, 1).last
  end

  def test_snapshot_returns_balances_and_max_seq
    @led.apply_econ(@acct, :money, 500, 3)
    @led.apply_econ(@acct, :coins, 20, 7)
    snap = @led.snapshot(@acct)
    assert_equal({ money: 500, coins: 20 }, snap[:balances])
    assert_equal 7, snap[:last_seq]
  end

  def test_ledger_audit_row_written
    @led.apply_econ(@acct, :money, 500, 1)
    @led.apply_econ(@acct, :money, 300, 2)
    rows = @db[:economy_ledger].where(account_id: @acct, field: "money").order(:seq).all
    assert_equal [500, 300], rows.map { |r| r[:balance_after] }
    assert_equal [500, -200], rows.map { |r| r[:delta] }
  end

  # Badges ride the ledger as ONE bitmask field. All 63 bits set == (1<<63)-1 ==
  # signed-bigint max == the cap, so it stores; bit 63 is one past the cap and is
  # refused BEFORE any INSERT (no wraparound-to-negative in the column).
  def test_badges_bitmask_acks_at_cap_and_rejects_over
    max = (1 << 63) - 1
    assert_equal [:ack, max], @led.apply_econ(@acct, :badges, max, 1)
    assert_equal max, @led.current(@acct, :badges)
    assert_equal [:rej, max, :cap], @led.apply_econ(@acct, :badges, 1 << 63, 2)
    assert_equal max, @led.current(@acct, :badges)
  end

  def test_snapshot_mixes_badges_and_money_with_global_max_seq
    @led.apply_econ(@acct, :money, 500, 4)
    @led.apply_econ(@acct, :badges, 0b1010, 9)
    snap = @led.snapshot(@acct)
    assert_equal 500,     snap[:balances][:money]
    assert_equal 0b1010,  snap[:balances][:badges]
    assert_equal 9,       snap[:last_seq]   # max across BOTH fields (the client's next-seq authority)
  end
end
