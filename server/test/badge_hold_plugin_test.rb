require "minitest/autorun"
require "rbconfig"

# Badge authority B2 on the client (docs/BADGE-AUTHORITY-DESIGN.md): when the server owns
# the badges, a badge frame waits while a trainer prize claim or a battle record of this
# connection has no answer (at most ~30 s) - the server shows a badge once the win it comes
# from is in - and goes out again after each answer. A battle whose win gives a badge waits
# for its seed longer, and asks it again on a new connection.
class BadgeHoldPluginTest < Minitest::Test
  SYNC  = File.expand_path("../../Plugins/PEMK/006_Sync/001_Sync.rb", __dir__)
  RNG   = File.expand_path("../../Plugins/PEMK/010_BattleRng/001_BattleRng.rb", __dir__)
  PRIZE = File.expand_path("../../Plugins/PEMK/009_BattleData/007_PrizeClaim.rb", __dir__)

  SYNC_RUNNER = <<~'RUBY'
    $sent = []; $unanswered = false; $unacked = false
    module Graphics; @f = 0; def self.frame_count; @f; end; def self.step(n); @f += n; end; end
    class FakeClient
      def connected?; true; end
      def send_message(m, _body = nil); $sent << m; end
    end
    class FakePlayer; def pokemmo_badges_mask; 0b11; end; end
    $player = FakePlayer.new
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.log(_m); end
      module Monsters; def self.pending_batch(_max = 64); [[], false]; end; def self.projection; nil; end; end
      module Flags; def self.active?; false; end; end
      module Trade; def self.busy?; false; end; end
      module TeamReport; def self.build; nil; end; end
      module Checkpoint; def self.request(_r); end; end
      module Inventory; def self.full_bag; nil; end; def self.stores; nil; end; end
      module PrizeClaim; def self.unanswered?; $unanswered; end; def self.holding?; false; end; def self.reset; end; end
      module BattleRng; def self.records_unacked?; $unacked; end; def self.reset; end; end
    end
    Temp = Struct.new(:in_battle)
    $game_temp = Temp.new(false)
    load ARGV[0]
    s = PEMK::Sync
    badges = -> { $sent.select { |m| m[:type] == :econ && m[:field] == :badges }.map { |m| m[:value] } }
    out = {}
    s.mark_econ(:badges, 0b1); s.flush_primitives
    out[:no_hold] = badges.()          # the server does not own them: out at once
    s.adopt_badge_hold(true); $unanswered = true
    s.mark_econ(:badges, 0b11); s.flush_primitives
    out[:claim] = badges.()            # a claim with no answer yet: the badges wait
    $unanswered = false; $unacked = true; s.flush_primitives
    out[:record] = badges.()           # ... a record not acknowledged too
    $unacked = false; s.flush_primitives
    out[:answered] = badges.()         # both in: out
    $unanswered = true
    s.mark_econ(:badges, 0b111); s.flush_primitives
    Graphics.step(1799); s.flush_primitives
    out[:bound_before] = badges.()
    Graphics.step(2); s.flush_primitives
    out[:bound] = badges.()            # at most ~30 s
    $unanswered = false
    s.remark_badges; s.flush_primitives
    out[:remark] = badges.()           # after an answer: the badges again
    s.reset
    s.remark_badges; s.flush_primitives
    out[:reset] = badges.()            # a new connection: until the login says so again
    print out.inspect
  RUBY

  def test_the_badges_wait_for_the_win_they_come_from
    out = IO.popen([RbConfig.ruby, "-W0", "-e", SYNC_RUNNER, SYNC], err: %i[child out], &:read)
    assert $?.success?, "sync runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal [1], got[:no_hold]
    assert_equal [1], got[:claim]
    assert_equal [1], got[:record]
    assert_equal [1, 3], got[:answered]
    assert_equal [1, 3], got[:bound_before]
    assert_equal [1, 3, 7], got[:bound]
    assert_equal [1, 3, 7, 3], got[:remark]
    assert_equal [1, 3, 7, 3], got[:reset]
  end

  RNG_RUNNER = <<~'RUBY'
    $sent = []; $now = 100.0; $up = true; $remarks = 0; $on_pump = nil
    module EventHandlers; def self.add(*); end; end
    module Graphics; def self.update; $now += 0.25; $on_pump&.call; end; end
    module Input; def self.update; end; end
    class Battle; def pbStartBattle; end; def pbRandom(x); 0; end; def pbCommandPhase; end
      def pbSwitchInBetween(*); end; def pbRun(*); end; def pbEndOfBattle; end; def pbDisplayConfirm(_m); end; end
    class Battle::AI; def pbAIRandom(x); 0; end; end
    class FakeClient; def connected?; $up; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 1; end
      def self.client; FakeClient.new; end
      def self.log(_m); end
      def self.send_message(m, _b = nil); $sent << m; true; end
      module Sync; def self.remark_badges; $remarks += 1; end; end
    end
    class GameTemp; attr_accessor :battle_rules; end
    class PokemonGlobalMetadata; attr_accessor :partner, :pemk_battle_records; end
    load ARGV[0]
    $game_temp = GameTemp.new
    $game_temp.battle_rules = {}
    $PokemonGlobal = PokemonGlobalMetadata.new
    rng = PEMK::BattleRng
    rng.define_singleton_method(:mono) { $now }
    Trainer = Struct.new(:pemk_key, :pemk_event)
    brock = Trainer.new(["LEADER_Brock", "Brock", 0], [10, 3])
    liam  = Trainer.new(["CAMPER", "Liam", 0], [10, 4])
    asks = -> { $sent.select { |m| m[:type] == :trainer_battle_req } }
    login = lambda do
      rng.adopt_mode("on"); rng.adopt_trainer_seed(true); rng.adopt_trainer_proof("on")
      rng.adopt_badge_battles([["LEADER_Brock", "Brock", 0, 10, 3], "junk"])
    end
    out = {}
    login.()
    $up = false
    rng.ask_trainer_seed(liam)
    out[:offline_other] = asks.().size         # no badge: nothing asked while the link is down
    rng.ask_trainer_seed(brock)
    out[:offline_badge] = asks.().size         # a badge: asked once the link is back
    # 5 s later the link is back (a new connection: reset, then the login); the server answers
    $on_pump = lambda do
      if !$up && $now >= 105.0
        $up = true
        rng.reset
        login.()
      elsif (req = asks.().last) && $now >= 106.0
        rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: req[:nonce], seed: 77 })
      end
    end
    t0 = $now
    out[:reconnected] = [rng.trainer_seed(brock), asks.().size, ($now - t0).round(2)]
    $on_pump = nil
    rng.ask_trainer_seed(brock)
    t0 = $now
    out[:late] = [rng.trainer_seed(brock), ($now - t0).round(2)]   # no answer: 30 s, then none
    rng.ask_trainer_seed(liam)
    t0 = $now
    out[:other_late] = [rng.trainer_seed(liam), ($now - t0).round(2)]   # no badge: 6 s
    out[:unacked] = rng.records_unacked?
    rng.adopt_record_ack(true)
    $PokemonGlobal.pemk_battle_records = [[5, { type: :battle_record }, "body"]]
    out[:kept] = rng.records_unacked?
    rng.on_record_ack({ rec_nonce: 5 })
    out[:acked] = [rng.records_unacked?, $remarks]
    print out.inspect
  RUBY

  def test_a_badge_battle_waits_for_its_seed_across_a_reconnect
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RNG_RUNNER, RNG], err: %i[child out], &:read)
    assert $?.success?, "rng runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval
    assert_equal 0, got[:offline_other]
    assert_equal 0, got[:offline_badge]
    assert_equal 77, got[:reconnected][0], "seeded, asked on the new connection"
    assert_equal 1, got[:reconnected][1]
    assert_operator got[:reconnected][2], :<=, 6.5
    assert_equal [nil, 30.0], got[:late]
    assert_equal [nil, 6.0], got[:other_late]
    assert_equal false, got[:unacked]
    assert_equal true, got[:kept]
    assert_equal [false, 1], got[:acked], "the badges go out again with the record in"
  end

  PRIZE_RUNNER = <<~'RUBY'
    $remarks = 0
    module EventHandlers; def self.add(*); end; end
    class FakeClient; def connected?; true; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 1; end
      def self.client; FakeClient.new; end
      def self.log(_m); end
      def self.send_message(_m, _b = nil); true; end
      module Sync; def self.remark_badges; $remarks += 1; end; end
    end
    class PokemonGlobalMetadata; attr_accessor :pemk_prize_claims; end
    load ARGV[0]
    $PokemonGlobal = PokemonGlobalMetadata.new
    $PokemonGlobal.pemk_prize_claims = [[1, [["LEADER_Brock", "Brock", 0, 10, 3]], 1400, false, false, 10, nil, 9],
                                        [2, :payday, 50, false, false, 5, {}]]
    pc = PEMK::PrizeClaim
    out = {}
    out[:sent] = pc.unanswered?
    pc.on_ack({ nonce: 1, verdict: "wait" })
    out[:wait] = [pc.unanswered?, $remarks]       # "wait" is no answer
    pc.on_ack({ nonce: 1, verdict: "held" })
    out[:held] = [pc.unanswered?, $remarks]       # held for its proof: in, the badges again
    pc.reset
    out[:reset] = pc.unanswered?                  # a new connection: asked again
    print out.inspect
  RUBY

  def test_a_claim_answered_lets_the_badges_go
    out = IO.popen([RbConfig.ruby, "-W0", "-e", PRIZE_RUNNER, PRIZE], err: %i[child out], &:read)
    assert $?.success?, "prize runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval
    assert_equal true, got[:sent]
    assert_equal [true, 0], got[:wait]
    assert_equal [false, 1], got[:held], "a Pay Day claim holds no badge"
    assert_equal true, got[:reset]
  end
end
