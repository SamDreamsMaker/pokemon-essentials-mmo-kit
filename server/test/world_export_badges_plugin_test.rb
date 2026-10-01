require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require "fileutils"

# Badge authority B0 (docs/BADGE-AUTHORITY-DESIGN.md): the world export says what gives
# each badge. A badge set at the own level of a trainer battle's win branch names that
# battle's trainers (the demo's Brock gives badge 0 so); one set anywhere else names none;
# a set the export cannot read is listed as unknown.
class WorldExportBadgesPluginTest < Minitest::Test
  EXPORT = File.expand_path("../../Plugins/PEMK/008_World/002_Export.rb", __dir__)

  RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]

    Cmd  = Struct.new(:code, :parameters, :indent)
    Page = Struct.new(:condition, :list)
    Ev   = Struct.new(:id, :x, :y, :pages)
    c = ->(code, params, indent = 0) { Cmd.new(code, params, indent) }
    gym = Ev.new(3, 6, 5, [Page.new(nil, [
      c.(111, [12, %q{TrainerBattle.start(:LEADER_Brock, "Brock")}]),
      c.(101, ["You've earned the Boulder Badge."], 1),
      c.(355, ["$stats.set_time_to_badge(0)"], 1),
      c.(655, ["$player.badges[0] = true"], 1),
      c.(411, [], 0),
      c.(355, ["$player.badges[7] = true"], 1),        # the loss's side: no win gives it
      c.(412, [], 0),
      c.(111, [12, "$player.badges[2] == true"]),      # a test, not a set
      c.(412, [], 0),
      c.(0, [])
    ])])
    pair = Ev.new(4, 1, 1, [Page.new(nil, [
      c.(111, [12, %q{TrainerBattle.start(:LEADER_A, "A", :LEADER_B, "B", 1)}]),
      c.(355, ["$Trainer.badges[4]=true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    npc = Ev.new(5, 2, 2, [Page.new(nil, [c.(355, ["$player.badges[1] = true"]), c.(0, [])]),
                           Page.new(nil, [c.(355, ["$player.badges[n] = true"]), c.(0, [])])])
    # the loss's branch of a negated call is no win
    lost = Ev.new(6, 3, 3, [Page.new(nil, [
      c.(111, [12, %q{!TrainerBattle.start(:LEADER_C, "C")}]),
      c.(355, ["pbPlayer.badges[5] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    # a battle that pays nothing: no prize, no claim to prove its win
    free = Ev.new(7, 4, 4, [Page.new(nil, [
      c.(355, [%q{setBattleRule("noMoney")}]),
      c.(111, [12, %q{TrainerBattle.start(:LEADER_D, "D")}]),
      c.(355, ["$player.badges[6] = true"], 1),
      c.(412, [], 0), c.(0, [])
    ])])
    print PEMK::WorldExport.badge_sources([[10, gym], [11, pair], [12, npc], [13, lost], [14, free]]).inspect
  RUBY

  def test_what_gives_each_badge
    out = IO.popen([RbConfig.ruby, "-W0", "-e", RUNNER, EXPORT], err: %i[child out], &:read)
    assert $?.success?, "runner crashed:\n#{out}"
    got = eval(out) # rubocop:disable Security/Eval - our own runner's inspect
    list = got[:list]
    assert_equal({ badge: 0, map: 10, event: 3, page: 0, trainers: [["LEADER_Brock", "Brock", 0]] }, list[0])
    assert_equal({ badge: 7, map: 10, event: 3, page: 0 }, list[1], "on the loss's side: no battle gives it")
    assert_equal({ badge: 4, map: 11, event: 4, page: 0, trainers: [["LEADER_A", "A", 0], ["LEADER_B", "B", 1]] },
                 list[2], "a double battle: either leader's win")
    assert_equal({ badge: 1, map: 12, event: 5, page: 0 }, list[3], "given by talking: no battle")
    assert_equal({ badge: 5, map: 13, event: 6, page: 0 }, list[4], "a negated battle's branch is the loss's")
    assert_equal({ badge: 6, map: 14, event: 7, page: 0, trainers: [["LEADER_D", "D", 0]], no_money: true }, list[5])
    assert_equal 6, list.size, "a test of a badge is no source"
    assert_equal [{ map: 12, event: 5, page: 1, script: "$player.badges[n] = true" }], got[:unknown]
  end

  # A game's own code setting a badge (a plugin, an edited script) is unknown to the
  # server; PEMK's own and the engine's debug menu are not the game's.
  CODE_RUNNER = <<~'RUBY'
    module PEMK; def self.log(_m); end; end
    module Settings; PHONE_REMATCHES_POSSIBLE_FROM_BEGINNING = false; end
    module GameData; module Trainer; def self.each; end; end; end
    load ARGV[0]
    print PEMK::WorldExport.badge_code_writes.inspect
  RUBY

  def test_the_game_s_own_code_setting_badges
    Dir.mktmpdir do |dir|
      { "Plugins/MyGame/badges.rb" => "# $player.badges[0] = true\ndef win\n  $player.badges[2] = true\nend\n",
        "Plugins/PEMK/004_Badges.rb" => "$player.badges[i] = v\n",
        "Data/Scripts/020_Debug/menu.rb" => "24.times { |i| $player.badges[i] = true }\n",
        "Data/Scripts/015_Player.rb" => "return $player.badges[1] == true\n" }.each do |path, text|
        FileUtils.mkdir_p(File.join(dir, File.dirname(path)))
        File.write(File.join(dir, path), text)
      end
      out = IO.popen([RbConfig.ruby, "-W0", "-e", CODE_RUNNER, EXPORT], err: %i[child out], chdir: dir, &:read)
      assert $?.success?, "runner crashed:\n#{out}"
      assert_equal [{ file: "Plugins/MyGame/badges.rb", line: 3, script: "$player.badges[2] = true" }], eval(out) # rubocop:disable Security/Eval
    end
  end
end
