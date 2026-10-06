require "minitest/autorun"

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "pemk/peer_sessions"

# Invites and sessions per pair and kind: an answer needs its invite, a teardown ends its
# own pair's session of its own kind, a player gone tells its partners.
class PeerSessionsTest < Minitest::Test
  def setup
    @p = PEMK::PeerSessions.new
  end

  def test_an_accept_opens_its_pair_and_kind_only
    @p.invite(1, 2, :battle)
    refute @p.answer(3, 1, :battle, accept: true), "not invited"
    refute @p.answer(2, 1, :trade, accept: true), "another kind"
    assert @p.answer(2, 1, :battle, accept: true)
    assert @p.session?(1, 2, :battle)
    assert @p.session?(2, 1, :battle)
    refute @p.session?(1, 2, :trade)
    refute @p.answer(2, 1, :battle, accept: true), "answered already"
  end

  def test_a_trade_is_its_trade_id
    @p.invite(1, 2, :trade, trade_id: "t")
    refute @p.answer(2, 1, :trade, accept: true, trade_id: "u")
    assert @p.answer(2, 1, :trade, accept: true, trade_id: "t")
    assert @p.session?(1, 2, :trade, trade_id: "t")
    refute @p.session?(1, 2, :trade, trade_id: "u")
  end

  def test_a_close_ends_its_own_only
    @p.invite(1, 2, :battle)
    @p.answer(2, 1, :battle, accept: true)
    @p.invite(3, 2, :trade, trade_id: "t")
    @p.answer(2, 3, :trade, accept: true, trade_id: "t")
    @p.close(2, 3, :trade, trade_id: "other")
    assert @p.session?(2, 3, :trade, trade_id: "t"), "another trade id"
    @p.close(2, 3, :trade, trade_id: "t")
    refute @p.session?(2, 3, :trade, trade_id: "t")
    assert @p.session?(1, 2, :battle), "the battle stands"
  end

  # One pair, a battle and a trade: ending the trade leaves the battle.
  def test_a_close_ends_its_own_kind_in_a_pair
    @p.invite(1, 2, :battle)
    @p.answer(2, 1, :battle, accept: true)
    @p.invite(2, 1, :trade, trade_id: "t")
    @p.answer(1, 2, :trade, accept: true, trade_id: "t")
    @p.close(1, 2, :trade, trade_id: "t")
    refute @p.session?(1, 2, :trade, trade_id: "t")
    assert @p.session?(1, 2, :battle)
  end

  def test_a_decline_drops_the_invite
    @p.invite(1, 2, :trade, trade_id: "t")
    assert @p.answer(2, 1, :trade, accept: false, trade_id: "t")
    refute @p.invited?(1, 2, :trade, trade_id: "t")
    refute @p.session?(1, 2, :trade, trade_id: "t")
  end

  def test_a_player_gone_tells_its_partners
    @p.invite(1, 2, :battle)
    @p.answer(2, 1, :battle, accept: true)
    @p.invite(1, 3, :trade, trade_id: "t")
    @p.answer(3, 1, :trade, accept: true, trade_id: "t")
    @p.invite(1, 4, :battle)
    assert_equal [[2, :battle, nil], [3, :trade, "t"]], @p.drop_account(1).sort_by(&:first)
    assert @p.invited?(1, 4, :battle), "an invite stays to its TTL (a relogin keeps a challenge)"
    assert_equal 1, @p.size
    assert_empty @p.drop_account(1), "told once"
  end

  def test_an_old_invite_is_forgotten
    now = Time.now
    @p.invite(1, 2, :battle, now: now - PEMK::PeerSessions::INVITE_TTL - 1)
    @p.invite(1, 3, :battle, now: now)
    @p.prune(now: now)
    refute @p.invited?(1, 2, :battle)
    assert @p.invited?(1, 3, :battle)
  end
end
