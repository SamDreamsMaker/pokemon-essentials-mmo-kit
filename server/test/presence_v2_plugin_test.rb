require "minitest/autorun"
require "rbconfig"

# Presence v2 on the client: a server that keeps idle players to itself and sends a leave
# for every player who goes (presence_v2 at login) - the client keeps its peers until one,
# sends a frame now and then even during a forced walk, asks who is there after it cleared
# its remotes, and clears them when the link drops. A client told nothing: as before.
class PresenceV2PluginTest < Minitest::Test
  PEMK_DIR = File.expand_path("../../Plugins/PEMK", __dir__)

  RUNNER = <<~'RUBY'
    $sent = []
    $now = 100.0
    module Graphics; def self.frame_count; 0; end; end
    module System; def self.uptime; $now; end; end
    class Game_Character; def initialize(*_args); end; end
    class Scene_Map; end
    class FakeClient; def connected?; true; end; end
    module PEMK
      def self.client; @client ||= FakeClient.new; end
      def self.self_id; 7; end
      def self.log(_m); end
      def self.send_message(m); $sent << m.dup; end
      module Config; HEARTBEAT_FRAMES = 30; PRESENCE_TIMEOUT = 3.0; end
    end
    Pl = Struct.new(:map_id, :x, :y, :direction, :move_speed, :character_name, :walking) do
      def moving?; walking; end
    end
    $game_player = Pl.new(5, 3, 4, 2, 3, "boy", false)
    $game_map = Object.new
    $player = nil
    load File.join(ARGV[0], "003_Game", "003_Presence.rb")
    load File.join(ARGV[0], "003_Game", "002_RemotePlayer.rb")
    pr = PEMK::Presence
    beats = lambda do |frames, moving|
      $sent.clear
      $game_player.walking = moving
      frames.times { pr.heartbeat }
      $sent.size
    end
    remotes = PEMK::Remotes
    prune_after = lambda do |seconds|
      remotes.instance_variable_set(:@players, { 9 => :remote })
      remotes.instance_variable_set(:@last_seen, { 9 => $now })
      $now += seconds
      remotes.prune
      remotes.players.key?(9)
    end
    out = {}
    out[:legacy] = [beats.(600, false), beats.(600, true), prune_after.(4)]
    remotes.clear_all
    beats.(30, false)
    out[:legacy_sync] = $sent.first.key?(:sync)
    pr.adopt_v2(true)
    out[:v2] = [beats.(600, false), beats.(600, true), prune_after.(60)]
    remotes.clear_all                 # a map change, a snap-back to another map, a lost link
    beats.(30, false)
    first = $sent.first
    beats.(30, false)
    out[:v2_sync] = [first[:sync], $sent.first.key?(:sync)]
    # the link drops: no leave will come, the remotes go (Dispatch's DISCONNECTED)
    module PEMK
      module NetClient; DISCONNECTED = :__disconnected__; end
      module PosCorrect; def self.reset; end; end
      module NetStatus; def self.on_disconnect; end; end
    end
    load File.join(ARGV[0], "003_Game", "004_Dispatch.rb")
    remotes.instance_variable_set(:@players, { 9 => :remote })
    PEMK::Dispatch.handle({ type: PEMK::NetClient::DISCONNECTED })
    out[:dropped] = remotes.players.empty?
    pr.adopt_v2(nil)                  # a server that says nothing
    out[:told_nothing] = [pr.v2?, prune_after.(4)]
    print out.inspect
  RUBY

  def test_a_v2_client_keeps_its_peers_and_asks_who_is_there
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, PEMK_DIR], err: %i[child out], &:read)
    assert $?.success?, "presence runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval
    assert_equal [20, 0, false], got[:legacy], "as before: idle beats every 30 frames, none walking, a 3 s timeout"
    assert_equal false, got[:legacy_sync]
    assert_equal [20, 2, true], got[:v2], "v2: a beat every 300 frames while walking too, no timeout"
    assert_equal [true, false], got[:v2_sync], "the first frame after a clear asks who is there, once"
    assert_equal true, got[:dropped], "a dropped link clears the remotes"
    assert_equal [false, false], got[:told_nothing], "a server that says nothing: back to the timeout"
  end
end
