require "minitest/autorun"
require "sequel"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/ledger"
require "pemk/config"

# Economy ledger: absolute-value apply, cap validation, gap-safe idempotency by
# ledger-row existence, materialized balance, login snapshot.
class LedgerTest < Minitest::Test
  CAPS = { money: 999_999, coins: 99_999, battle_points: 9_999, soot: 9_999, badges: (1 << 63) - 1 }.freeze

  def setup
    @db = Sequel.connect(ENV.fetch("DATABASE_URL"))
    @db[:monster_transfers].delete rescue nil
    @db[:monsters].delete rescue nil   # no cascade from accounts (deliberate)
    @db[:enforcement_events].delete rescue nil
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

  # A frame's seq is the client's: one the ledger never applies is never recorded, and
  # asking is no query the database refuses (text, or past bigint).
  def test_recorded_with_a_bad_seq_is_false
    @led.apply_econ(@acct, :money, 500, 1)
    assert @led.recorded?(@acct, :money, 1)
    refute @led.recorded?(@acct, :money, "1")
    refute @led.recorded?(@acct, :money, 1 << 70)
    refute @led.recorded?(@acct, :money, 0)
    refute PEMK::Ledger.seq_ok?(PEMK::Ledger::SEQ_MAX)
    assert PEMK::Ledger.seq_ok?(PEMK::Ledger::SEQ_MAX - 1)
  end

  # Badge authority B2: only the server raises the badges.
  def test_grant_bits_is_bitwise_and_the_server_s_own
    @led.apply_econ(@acct, :badges, 0b1, 5)
    assert_equal 0b11, @led.grant_bits(@acct, 0b10, reason: "badge:proof:7",
                                             grants: [{ badge: 1, evidence: "proof", source: "claim 7", claim_nonce: 7 }])
    assert_equal 0b11, @led.grant_bits(@acct, 0b10, reason: "again"), "a bit owned: nothing moves"
    assert_equal 0b11, @led.current(@acct, :badges)
    rows = @db[:economy_ledger].where(account_id: @acct, field: "badges").order(:seq).all
    assert_equal [[-1, 0b10, "badge:proof:7"], [5, 0b1, "unattributed"]], rows.map { |r| r.values_at(:seq, :delta, :reason) }
    assert_equal 5, @db[:economy_balances].where(account_id: @acct, field: "badges").get(:last_seq), "the client's seq stays"
    assert_equal [[1, "proof", 7]], @db[:badge_grants].where(account_id: @acct).select_map(%i[badge evidence claim_nonce])
    grant = -> { @db[:badge_grants].where(account_id: @acct, badge: 1).get(%i[evidence claim_nonce]) }
    assert_equal 0b1, @led.revoke_bits(@acct, 0b10, reason: "badge:revoked", source: "op: a mistake")
    assert_equal ["revoked", nil], grant.(), "kept as revoked"
    @led.grant_bits(@acct, 0b10, reason: "proof", grants: [{ badge: 1, evidence: "proof", claim_nonce: 8 }])
    assert_equal ["proof", 8], grant.(), "a new grant takes a revoked one's place"
    @led.grant_bits(@acct, 0b10, reason: "again", grants: [{ badge: 1, evidence: "operator" }])
    assert_equal ["proof", 8], grant.(), "a grant stands"
  end

  # Two grants at once, each reading before the other writes: the row's lock makes the
  # second read the first's write - a stale read would lose a badge (or, as an adjust's
  # delta, carry into one nobody earned).
  def test_grants_at_once_lose_nothing
    @led.grant_bits(@acct, 0b1, reason: "first")
    [0b10, 0b100].map do |bit|
      Thread.new do
        PEMK::Ledger.new(@db, CAPS).send(:set_badges, @acct, reason: "race", now: Time.now) do |cur|
          sleep 0.2   # the other grant reads meanwhile
          cur | bit
        end
      end
    end.each(&:join)
    assert_equal 0b111, @led.current(@acct, :badges)
  end

  # The boot pass's write: what it adds and removes, under the lock - a bit granted since
  # its plan was made stays.
  def test_rebase_keeps_a_grant_made_since
    @led.grant_bits(@acct, 0b0110, reason: "before")
    @db[:badge_grants].insert(account_id: @acct, badge: 2, evidence: "operator", granted_at: Time.now)
    assert_equal 0b1101, @led.rebase_badge_bits(@acct, add: 0b1001, remove: 0b0110, reason: "badge:boot"),
                 "badge 1 removed, 0 and 3 added - badge 2 granted meanwhile stays"
    @led.revoke_bits(@acct, 0b100, reason: "revoked")
    @led.grant_bits(@acct, 0b100, reason: "a frame's bit, as a period off left it")
    assert_equal 0b1001, @led.rebase_badge_bits(@acct, add: 0, remove: 0b100, reason: "badge:boot"),
                 "a revoked grant keeps nothing"
  end

  def test_a_held_frame_moves_nothing
    @led.grant_bits(@acct, 0b1, reason: "proof")
    assert_equal [:held, 0b1], @led.apply_econ(@acct, :badges, 0b111, 3, hold: true)
    assert_equal [:held, 0b1], @led.apply_econ(@acct, :badges, 0, 4, hold: true), "nor drops a bit"
    assert_equal 0b1, @led.current(@acct, :badges)
    assert @led.recorded?(@acct, :badges, 4)
    assert_equal [:dup, 0b1], @led.apply_econ(@acct, :badges, 0b111, 3, hold: true)
    assert_equal 4, @db[:economy_balances].where(account_id: @acct, field: "badges").get(:last_seq)
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
  # --- badges are progression, not currency ------------------------------------
  # A reloaded save that predates a badge pushes a smaller mask. Assigning it erases
  # earned progress - seen in a live session right after a rollback. Unioning keeps it
  # and the ack hands the repaired mask straight back to the client.

  def monotonic_ledger
    PEMK::Ledger.new(@db, PEMK::Config.new.economy_caps, monotonic: true)
  end

  def test_badges_union_instead_of_shrinking
    led = monotonic_ledger
    assert_equal [:ack, 0b0011], led.apply_econ(@acct, :badges, 0b0011, 1)
    assert_equal [:ack, 0b0011], led.apply_econ(@acct, :badges, 0, 2)         # rollback
    assert_equal 0b0011, led.current(@acct, :badges)
  end

  def test_badges_still_grow_normally
    led = monotonic_ledger
    led.apply_econ(@acct, :badges, 0b0001, 1)
    assert_equal [:ack, 0b0101], led.apply_econ(@acct, :badges, 0b0100, 2)   # earned another
  end

  def test_money_is_not_monotonic
    led = monotonic_ledger
    led.apply_econ(@acct, :money, 5000, 1)
    assert_equal [:ack, 100], led.apply_econ(@acct, :money, 100, 2)          # spending works
  end

  def test_monotonic_is_off_by_default
    led = PEMK::Ledger.new(@db, PEMK::Config.new.economy_caps)
    led.apply_econ(@acct, :badges, 0b0011, 1)
    assert_equal [:ack, 0], led.apply_econ(@acct, :badges, 0, 2)
  end

end
