require "minitest/autorun"
require "rbconfig"

# Mode keys, the move half, on the client: a move learned or forgotten by a party Pokemon
# marks the party channel (another Pokemon's marks nothing), a swim's start flushes it
# before the engine moves the player, and the team report says which Pokemon is an egg.
class SwimReportPluginTest < Minitest::Test
  PLUGIN = File.expand_path("../../Plugins/PEMK/009_BattleData/003_SwimReport.rb", __dir__)
  REPORT = File.expand_path("../../Plugins/PEMK/009_BattleData/002_TeamReport.rb", __dir__)

  RUNNER = <<~'RUBY'
    $log = []
    module PEMK
      def self.log(m); $log << [:err, m]; end
      module Sync
        def self.mark_mon; $log << :mark; end
        def self.flush_party; $log << :flush_party; end
      end
    end
    class Pokemon
      attr_reader :moves
      def initialize; @moves = []; end
      def learn_move(m); @moves << m; :learned; end
      def forget_move(m); @moves.delete(m); end
      def forget_move_at_index(i); @moves.delete_at(i); end
      def forget_all_moves; @moves.clear; end
    end
    Trainer = Struct.new(:party)
    def pbStartSurfing; $log << :surfing; end
    def pbDive; $log << :diving; :dived; end
    def pbSurfacing; $log << :surfacing; end
    def pbSmashEvent(event); $log << [:smash, event]; end
    def pbAscendWaterfall; $log << :climbing; end
    class Interpreter
      def pbPushThisEvent(strength = false); $log << [:push, strength]; end
    end
    load ARGV[0]

    mine  = Pokemon.new
    other = Pokemon.new
    $player = Trainer.new([mine, nil])
    raise "learn_move's result lost" unless mine.learn_move(:SURF) == :learned
    mine.forget_move(:SURF); mine.forget_move_at_index(0); mine.forget_all_moves
    other.learn_move(:SURF)                      # a trainer's, a wild one: not the party's
    $player = nil
    mine.learn_move(:TACKLE)                     # before any game is loaded
    $player = Trainer.new([mine])
    raise "pbDive's result lost" unless pbDive == :dived
    pbStartSurfing
    pbSurfacing
    pbSmashEvent(:tree)                          # a field gate opens: the report first
    pbAscendWaterfall
    Interpreter.new.pbPushThisEvent(true)
    print $log.inspect
  RUBY

  def test_moves_mark_and_a_swim_flushes_first
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PLUGIN], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    assert_equal [:mark, :mark, :mark, :mark, :flush_party, :diving, :flush_party, :surfing, :flush_party, :surfacing,
                  :flush_party, [:smash, :tree], :flush_party, :climbing, :flush_party, [:push, true]],
                 eval(out) # rubocop:disable Security/Eval
  end

  EGG = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    class Stub
      def initialize(egg); @egg = egg; end
      def egg?; @egg; end
      def level; 5; end
      def moves; []; end
      def species; :TOGEPI; end
      def method_missing(*); nil; end
      def respond_to_missing?(*); true; end
    end
    load ARGV[0]
    print [PEMK::TeamReport.mon(Stub.new(true))["egg"], PEMK::TeamReport.mon(Stub.new(false))["egg"]].inspect
  RUBY

  def test_the_report_says_which_pokemon_is_an_egg
    out = IO.popen([RbConfig.ruby, "-W0", "-e", EGG, REPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    assert_equal "[true, false]", out.strip
  end
end
