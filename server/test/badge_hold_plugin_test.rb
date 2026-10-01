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
    $now = 100.0
    s.define_singleton_method(:mono) { $now }
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
    $now += 59.9; s.flush_primitives
    out[:bound_before] = badges.()
    $now += 0.2; s.flush_primitives
    out[:bound] = badges.()            # at most 60 s, by the clock
    $unanswered = false
    s.remark_badges; s.flush_primitives
    out[:remark] = badges.()           # after an answer: the badges again
    s.reset
    s.remark_badges; s.flush_primitives
    out[:reset] = badges.()            # a new connection: until the login says so again
    s.adopt_badge_hold(true)
    s.remark_badges; s.flush_primitives
    out[:none_sent] = badges.()        # no badge frame out on this connection: nothing to correct
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
    assert_equal [1, 3, 7, 3], got[:none_sent], "an answer before any badge frame: the badge's own frame comes"
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
    rng.ask_trainer_seed(brock)
    out[:offline] = asks.().size               # the link down: nothing asked (no seed, an unprovable win)
    $up = true
    $on_pump = lambda do                       # the server answers 8 s later
      req = asks.().last
      rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: req[:nonce], seed: 77 }) if req && $now >= 108.0
    end
    rng.ask_trainer_seed(brock)
    out[:slow] = rng.trainer_seed(brock)       # a badge's battle waits past 6 s
    $on_pump = nil
    rng.ask_trainer_seed(brock)
    t0 = $now
    out[:late] = [rng.trainer_seed(brock), ($now - t0).round(2)]   # no answer: 30 s, then none
    rng.ask_trainer_seed(liam)
    t0 = $now
    out[:other_late] = [rng.trainer_seed(liam), ($now - t0).round(2)]   # no badge: 6 s
    rng.ask_trainer_seed(brock)
    $on_pump = -> { $up = false if $now >= 120.0 }   # the link goes: no more waiting
    t0 = $now
    out[:dropped] = [rng.trainer_seed(brock), ($now - t0) < 30]
    $on_pump = nil
    $up = true
    out[:unacked] = rng.records_unacked?
    rng.adopt_record_ack(true)
    $PokemonGlobal.pemk_battle_records = [[5, { type: :battle_record }, "body"]]
    out[:kept] = rng.records_unacked?
    rng.on_record_ack({ rec_nonce: 5 })
    rng.on_record_ack({ rec_nonce: 5 })        # an answer again: nothing new
    out[:acked] = [rng.records_unacked?, $remarks]
    print out.inspect
  RUBY

  def test_a_badge_battle_waits_longer_for_its_seed
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RNG_RUNNER, RNG], err: %i[child out], &:read)
    assert $?.success?, "rng runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval
    assert_equal 0, got[:offline]
    assert_equal 77, got[:slow], "seeded after 8 s"
    assert_equal [nil, 30.0], got[:late]
    assert_equal [nil, 6.0], got[:other_late]
    assert_equal [nil, true], got[:dropped], "the link gone: the start goes on"
    assert_equal false, got[:unacked]
    assert_equal true, got[:kept]
    assert_equal [false, 1], got[:acked], "the badges go out again with the record in - once"
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
    pc.on_ack({ nonce: 1, verdict: "held" })      # asked again 10 s later: nothing new
    out[:held] = [pc.unanswered?, $remarks]       # held for its proof: in, the badges again - once
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
