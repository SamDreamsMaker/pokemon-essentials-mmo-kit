require "minitest/autorun"
require "rbconfig"

# Trainer proof P2 on the client: a trainer loaded for a battle asks its placement's seed
# (only under `on`, when the server says it seeds trainers, for a trainer the game's data
# built from an event); the battle's start waits for the answer, at most two seconds,
# and runs unseeded when it is a refusal or does not come.
class TrainerSeedPluginTest < Minitest::Test
  RNG = File.expand_path("../../Plugins/PEMK/010_BattleRng/001_BattleRng.rb", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []; $now = 100.0; $pumps = 0
    module EventHandlers; def self.add(*); end; end
    module Graphics; def self.update; $pumps += 1; $now += 0.25; end; end
    module Input; def self.update; end; end
    class Battle; def pbStartBattle; end; def pbRandom(x); 0; end; def pbCommandPhase; end
      def pbSwitchInBetween(*); end; def pbRun(*); end; def pbEndOfBattle; end; def pbDisplayConfirm(_m); end; end
    class Battle::AI; def pbAIRandom(x); 0; end; end
    class FakeClient; def connected?; true; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 1; end
      def self.client; FakeClient.new; end
      def self.log(_m); end
      def self.send_message(m, _b = nil); $sent << m; true; end
    end
    load ARGV[0]
    PEMK::BattleRng.define_singleton_method(:mono) { $now }
    Trainer = Struct.new(:pemk_key, :pemk_event)
    rng = PEMK::BattleRng
    liam = Trainer.new(["CAMPER", "Liam", 0], [10, 4])
    out = {}

    rng.adopt_mode("shadow"); rng.adopt_trainer_seed(true)
    rng.ask_trainer_seed(liam)
    out[:shadow] = $sent.size                                  # shadow: nothing asked
    rng.adopt_mode("on"); rng.adopt_trainer_seed(false)
    rng.ask_trainer_seed(liam)
    out[:not_offered] = $sent.size                             # the server does not seed trainers
    rng.adopt_trainer_seed(true)
    rng.ask_trainer_seed(Trainer.new(["CAMPER", "Liam", 0], nil))
    out[:no_event] = $sent.size                                # not from an event: nothing to name

    rng.ask_trainer_seed(liam)
    out[:asked] = $sent.last
    rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: $sent.last[:nonce], seed: 42 })
    rng.on_trainer_seed({ type: :trainer_battle_seed, nonce: 999, seed: 7 })   # nobody asked
    out[:seeded] = [rng.trainer_seed(liam), $pumps]

    brock = Trainer.new(["LEADER_Brock", "Brock", 0], [10, 3])
    rng.ask_trainer_seed(brock)
    rng.on_trainer_seed({ type: :trainer_battle_deny, nonce: $sent.last[:nonce], reason: "not_here" })
    out[:denied] = rng.trainer_seed(brock)

    ariel = Trainer.new(["SWIMMER2_F", "Ariel", 0], [69, 5])
    rng.ask_trainer_seed(ariel)
    t0 = $now
    out[:late] = [rng.trainer_seed(ariel), ($now - t0).round(2)]   # no answer: two seconds, then none
    print out.inspect
  RUBY

  # Trainer proof P4: a seed is asked only for a battle the recorder arms (a single battle,
  # no partner at the player's side); its prize paid on the replay, the start waits longer;
  # a trainer battle's record is kept in the save until the server acknowledges it.
  P4_RUNNER = <<~'RUBY'
    $sent = []; $now = 100.0
    module EventHandlers; def self.add(*); end; end
    module Graphics; def self.update; $now += 0.25; end; end
    module Input; def self.update; end; end
    class Battle; def pbStartBattle; end; def pbRandom(x); 0; end; def pbCommandPhase; end
      def pbSwitchInBetween(*); end; def pbRun(*); end; def pbEndOfBattle; end; def pbDisplayConfirm(_m); end; end
    class Battle::AI; def pbAIRandom(x); 0; end; end
    class FakeClient; def connected?; true; end; end
    module PEMK
      def self.enabled?; true; end
      def self.self_id; 1; end
      def self.client; FakeClient.new; end
      def self.log(_m); end
      def self.send_message(m, b = nil); $sent << [m, b]; true; end
      module MessageCodec; def self.encode_primitive(_h); "record-body"; end; end
    end
    class GameTemp; attr_accessor :battle_rules; end
    class PokemonGlobalMetadata; attr_accessor :partner; end
    load ARGV[0]
    $game_temp = GameTemp.new
    $game_temp.battle_rules = {}
    $PokemonGlobal = PokemonGlobalMetadata.new
    rng = PEMK::BattleRng
    rng.define_singleton_method(:mono) { $now }
    Trainer = Struct.new(:pemk_key, :pemk_event)
    liam = Trainer.new(["CAMPER", "Liam", 0], [10, 4])
    asks = -> { $sent.count { |m, _| m[:type] == :trainer_battle_req } }
    out = {}

    rng.adopt_mode("on"); rng.adopt_trainer_seed(true)
    $game_temp.battle_rules = { "size" => "double" }
    rng.ask_trainer_seed(liam)
    out[:double] = asks.call
    $game_temp.battle_rules = { "size" => "1v1" }
    rng.ask_trainer_seed(liam)
    out[:single] = asks.call
    $game_temp.battle_rules = {}
    $PokemonGlobal.partner = [:POKEMONTRAINER_May, "May", 0, []]
    rng.ask_trainer_seed(liam)
    out[:partner] = asks.call
    $game_temp.battle_rules = { "noPartner" => true }
    rng.ask_trainer_seed(liam)
    out[:no_partner_rule] = asks.call
    $PokemonGlobal.partner = nil
    $game_temp.battle_rules = {}
    rng.adopt_trainer_proof("on")
    rng.ask_trainer_seed(liam)
    t0 = $now
    out[:proof_wait] = [rng.trainer_seed(liam), ($now - t0).round(2)]

    # records: a battle's session keeps its record as it was armed
    $sent.clear
    fake = Struct.new(:opponent, :player) do
      def trainerBattle?; true; end
      def pbSideSize(_i); 1; end
    end
    rng.adopt_mode("shadow")
    rng.adopt_record_ack(false)
    out[:not_offered] = rng.arm_trainer(fake.new([liam], [1])).keep
    rng.adopt_record_ack(true)
    s = rng.arm_trainer(fake.new([liam], [1]))
    rng.reset                    # the link lost mid-battle
    s.finalize_and_send          # sent nowhere, kept
    rng.adopt_record_ack(true)   # the next login
    env, body = $sent.last
    n = env[:rec_nonce]
    out[:sent] = [env[:type], body, n.is_a?(Integer), rng.kept_records.map(&:first) == [n]]
    w = PEMK::BattleRng::Session.new(:shadow, nil)
    w.finalize_and_send
    out[:wild] = [$sent.last[0].key?(:rec_nonce), rng.kept_records.size]
    $sent.clear
    rng.send_records
    out[:not_yet] = $sent.size
    $now += 31
    rng.send_records
    out[:again] = $sent.map { |m, _| m[:rec_nonce] } == [n]
    rng.on_record_ack({ rec_nonce: n })
    out[:acked] = rng.kept_records.size
    5.times { rng.keep_record({ type: :battle_record }, "b" * 10) }
    out[:kept] = rng.kept_records.size
    rng.keep_record({ type: :battle_record }, "c" * 200_000)
    out[:big] = rng.kept_records.map { |e| e[2].size }
    rng.reset
    rng.adopt_record_ack(true)
    $sent.clear
    rng.send_records
    out[:new_connection] = $sent.size
    print out.inspect
  RUBY

  def test_p4_what_is_asked_and_what_is_kept
    out = IO.popen([RbConfig.ruby, "-W0", "-e", P4_RUNNER, RNG], err: %i[child out], &:read)
    assert $?.success?, "P4 runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal 0, got[:double], "a double battle is never recorded: no seed asked"
    assert_equal 1, got[:single]
    assert_equal 1, got[:partner], "a partner at the player's side: none asked"
    assert_equal 2, got[:no_partner_rule], "a battle the partner sits out"
    assert_equal [nil, 6.0], got[:proof_wait], "its prize paid on its replay: six seconds"
    assert_equal false, got[:not_offered], "a server that acknowledges nothing: the battle keeps nothing"
    assert_equal [:battle_record, "record-body", true, true], got[:sent]
    assert_equal [false, 1], got[:wild], "a wild battle's record is not kept"
    assert_equal 0, got[:not_yet], "sent just now"
    assert got[:again], "unacknowledged after RECORD_RESEND: sent again"
    assert_equal 0, got[:acked]
    assert_equal 4, got[:kept], "RECORDS_KEPT at most"
    assert_equal [200_000], got[:big], "RECORDS_KEPT_MAX bytes: the oldest go"
    assert_equal 1, got[:new_connection], "a new connection sends it again"
  end

  def test_a_trainer_battle_asks_and_waits_for_its_seed
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, RNG], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    assert_equal 0, got[:shadow]
    assert_equal 0, got[:not_offered]
    assert_equal 0, got[:no_event]
    assert_equal :trainer_battle_req, got[:asked][:type]
    assert_equal [["CAMPER", "Liam", 0, 10, 4]], got[:asked][:trainers]
    assert_equal [42, 0], got[:seeded], "answered already: no wait"
    assert_nil got[:denied]
    assert_equal [nil, 2.0], got[:late]
  end
end
